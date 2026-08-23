import AVFoundation
import AppKit
import Foundation

/// Mic capture at 16 kHz mono Float32 — the format Whisper wants.
///
/// The engine's tap runs on a realtime audio thread. Two rules follow from
/// that and drive this whole file: never allocate inside the callback (the
/// buffer is preallocated to the max recording length), and never touch the
/// main actor from it (levels are published on a timer instead, §5.2).
public final class AudioRecorder: @unchecked Sendable {

    public enum RecorderError: LocalizedError {
        case formatUnavailable
        case converterUnavailable
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .formatUnavailable:
                return "The input device did not report a usable audio format."
            case .converterUnavailable:
                return "Could not convert the input audio to 16 kHz mono."
            case .engineFailed(let message):
                return "Audio engine failed to start: \(message)"
            }
        }
    }

    public static let sampleRate: Double = 16_000

    /// Called ~30×/s on the main actor with a 0…1 level for the meter.
    @MainActor public var onLevel: ((Float) -> Void)?
    /// Called on the main actor if capture dies mid-recording.
    @MainActor public var onFailure: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    /// Preallocated. `capacity` is maxRecordingSeconds × 16 kHz.
    private var buffer: [Float] = []
    private var writeIndex = 0
    private var didOverflow = false
    private var currentRMS: Float = 0

    private var levelTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    public private(set) var isRecording = false

    public init() {}

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: Control

    public func start(maxSeconds: Double) throws {
        guard !isRecording else { return }

        let capacity = Int(maxSeconds * Self.sampleRate)
        lock.lock()
        buffer = [Float](repeating: 0, count: capacity)
        writeIndex = 0
        didOverflow = false
        currentRMS = 0
        lock.unlock()

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw RecorderError.formatUnavailable
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: target)
        else { throw RecorderError.converterUnavailable }

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) {
            [weak self] pcmBuffer, _ in
            self?.append(pcmBuffer, using: converter, target: target)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        startLevelTimer()
        observeInterruptions()
    }

    /// Stops capture and returns everything recorded, in order.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        teardown()

        lock.lock()
        defer { lock.unlock() }
        // The buffer is a plain preallocated array, not a circular one: on
        // overflow we keep the first `capacity` samples and drop the tail,
        // which is what the max-duration cap means.
        return Array(buffer[0..<writeIndex])
    }

    public func cancel() {
        guard isRecording else { return }
        teardown()
        lock.lock()
        buffer = []
        writeIndex = 0
        lock.unlock()
    }

    /// Seconds captured so far.
    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(writeIndex) / Self.sampleRate
    }

    public var hasOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }

    // MARK: Capture

    private func append(_ pcmBuffer: AVAudioPCMBuffer,
                        using converter: AVAudioConverter,
                        target: AVAudioFormat) {
        let ratio = target.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: capacity)
        else { return }

        // The input block is typed @Sendable but AVAudioConverter calls it
        // synchronously, on this thread, before convert() returns — nothing
        // here actually escapes.
        nonisolated(unsafe) let source = pcmBuffer
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }

        guard error == nil,
              let samples = converted.floatChannelData?[0],
              converted.frameLength > 0
        else { return }

        let count = Int(converted.frameLength)

        var sumOfSquares: Float = 0
        for i in 0..<count { sumOfSquares += samples[i] * samples[i] }
        let rms = (sumOfSquares / Float(count)).squareRoot()

        lock.lock()
        let room = buffer.count - writeIndex
        if room <= 0 {
            didOverflow = true
        } else {
            let copied = min(room, count)
            for i in 0..<copied { buffer[writeIndex + i] = samples[i] }
            writeIndex += copied
            if copied < count { didOverflow = true }
        }
        currentRMS = rms
        lock.unlock()
    }

    // MARK: Level metering

    private func startLevelTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let rms = self.currentRMS
            self.lock.unlock()
            // Perceptual, not linear: raw RMS from speech sits so low that a
            // linear bar looks broken.
            let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 60) / 60))
            Task { @MainActor [weak self] in self?.onLevel?(level) }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    // MARK: Interruptions

    /// A device change or a wake from sleep invalidates the engine (§9). Both
    /// surface as a failure so the coordinator can end the session cleanly
    /// rather than record silence forever.
    private func observeInterruptions() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            Task { @MainActor [weak self] in
                self?.onFailure?(RecorderError.engineFailed("The audio device changed."))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            Task { @MainActor [weak self] in
                self?.onFailure?(RecorderError.engineFailed("The Mac woke from sleep."))
            }
        }
    }

    private func teardown() {
        isRecording = false
        levelTimer?.invalidate()
        levelTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        Task { @MainActor [weak self] in self?.onLevel?(0) }
    }
}