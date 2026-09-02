import AVFoundation
import AppKit
import CoreAudio
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
        case deviceUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .formatUnavailable:
                return "The input device did not report a usable audio format."
            case .converterUnavailable:
                return "Could not convert the input audio to 16 kHz mono."
            case .engineFailed(let message):
                return "Audio engine failed to start: \(message)"
            case .deviceUnavailable(let name):
                return "\(name) is not available."
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

    /// Serialises every touch of the engine.
    ///
    /// `start()` runs on a background task and takes ~400 ms, most of it in
    /// the hardware. `cancel()` arrives from the main actor whenever the user
    /// presses Esc — and if that lands inside that window, the next key press
    /// starts a second capture against an engine the first is still
    /// configuring. Two threads in `installTap` at once ends in an
    /// Objective-C exception that Swift cannot catch, and the app is gone.
    /// Seen four times in crash reports before this lock existed.
    private let engineLock = NSLock()
    /// Guarded by `lock`. Bumped by every `cancel()`. A `start()` notes the
    /// value on entry and, if it has moved by the time the hardware is up,
    /// tears down again instead of leaving a hot microphone nobody knows
    /// about. A counter rather than a flag so that two cancels and two
    /// starts inside one ~400 ms window still pair up correctly.
    private var cancelCount = 0

    /// Preallocated. `capacity` is maxRecordingSeconds × 16 kHz.
    private var buffer: [Float] = []
    private var writeIndex = 0
    private var didOverflow = false
    private var currentRMS: Float = 0

    /// The format the current tap and converter were built for. Only ever
    /// touched under `engineLock`.
    private var tapFormat: AVAudioFormat?

    private var levelTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    public private(set) var isRecording = false

    /// Where the time went in the last `start()`, for latency work. Cheap
    /// enough to always collect: a handful of clock reads.
    public private(set) var startBreakdown: [(phase: String, milliseconds: Double)] = []

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

    /// - Parameter deviceUID: the microphone to record from, or nil to follow
    ///   the system default. A device that is no longer attached falls back to
    ///   the default rather than failing the recording — losing the words
    ///   because a headset was unplugged would be the worse outcome.
    ///
    /// Throws `CancellationError` if `cancel()` was called while the hardware
    /// was still waking up: the capture never became live and nothing is
    /// left running.
    public func start(maxSeconds: Double, deviceUID: String? = nil) throws {
        // A second start waits for the one in flight to finish rather than
        // racing it. That one either becomes the recording, in which case
        // this returns early below, or was cancelled, in which case this one
        // starts on a clean engine.
        lock.lock()
        let cancelsAtEntry = cancelCount
        lock.unlock()

        engineLock.lock()
        defer { engineLock.unlock() }
        guard !isRecording else { return }

        startBreakdown = []
        var mark = ContinuousClock.now
        func lap(_ phase: String) {
            let now = ContinuousClock.now
            startBreakdown.append(
                (phase, Double((now - mark).components.attoseconds) / 1e15))
            mark = now
        }

        let capacity = Int(maxSeconds * Self.sampleRate)
        lock.lock()
        buffer = [Float](repeating: 0, count: capacity)
        writeIndex = 0
        didOverflow = false
        currentRMS = 0
        lock.unlock()
        lap("buffer")

        let input = engine.inputNode
        lap("inputNode")

        // Before the format is read, not after: the format belongs to whatever
        // device the unit is pointed at, so asking first would describe the
        // old one.
        if let deviceUID, let device = AudioDevices.device(forUID: deviceUID) {
            try selectDevice(device.deviceID, on: input)
        }
        lap("selectDevice")

        try installTap(on: input)
        lap("installTap")

        engine.prepare()
        lap("prepare")
        do {
            try engine.start()
            lap("engineStart")
        } catch {
            // One retry, after a reset. AVAudioEngine caches its input node,
            // and a node created while the microphone permission did not exist
            // yet holds a dead format — which is a first run, and exactly when
            // an alert about the audio engine is least welcome.
            engine.reset()
            do {
                try installTap(on: engine.inputNode)
                engine.prepare()
                try engine.start()
                lap("engineStart")
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                tapFormat = nil
                throw RecorderError.engineFailed(error.localizedDescription)
            }
        }

        lock.lock()
        let cancelled = cancelCount != cancelsAtEntry
        if !cancelled { isRecording = true }
        lock.unlock()

        if cancelled {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapFormat = nil
            throw CancellationError()
        }

        startLevelTimer()
        observeInterruptions()
    }

    /// Stops capture and returns everything recorded, in order.
    @discardableResult
    public func stop() -> [Float] {
        engineLock.lock()
        defer { engineLock.unlock() }
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
        // Counted before anything else, so a start still waking the hardware
        // sees it. That start then tears itself down; waiting for it here
        // would stall the main actor on the microphone.
        lock.lock()
        cancelCount &+= 1
        let recording = isRecording
        lock.unlock()
        guard recording else { return }

        engineLock.lock()
        defer { engineLock.unlock() }
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

    /// Build the converter for the device's current format and start feeding
    /// the buffer.
    ///
    /// Separate from `start()` because a device change mid-recording invalidates
    /// the converter: it was built for the old format, and left in place it
    /// turns everything after the change into noise.
    private func installTap(on input: AVAudioInputNode) throws {
        input.removeTap(onBus: 0)
        tapFormat = nil

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
        tapFormat = hwFormat
    }

    /// Point the engine's input at a specific device.
    ///
    /// AVAudioEngine has no API for this on macOS; it is a property on the
    /// AUHAL unit underneath, and it only takes while the engine is stopped.
    private func selectDevice(_ deviceID: AudioDeviceID,
                              on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw RecorderError.engineFailed("The input node has no audio unit.")
        }

        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))

        guard status == noErr else {
            throw RecorderError.engineFailed(
                "Could not select that microphone (error \(status)).")
        }
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
        // start() runs off the main actor now, and adding a timer to the main
        // run loop from another thread is not safe. Built and scheduled there.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleLevelTimer()
        }
    }

    private func scheduleLevelTimer() {
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
            self.handleConfigurationChange()
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

    /// The engine reconfigured underneath us.
    ///
    /// This is NOT a failure, and treating it as one is what produced an
    /// "Audio engine failed to start" alert on a first run: macOS posts a
    /// configuration change as soon as the input device initialises, so the
    /// engine had started perfectly well and then been declared broken.
    ///
    /// §5.2 asks for a restart, which is also what keeps a genuine mid-session
    /// device change from turning the rest of the recording into noise — the
    /// converter belongs to the format it was built for.
    private func handleConfigurationChange() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard isRecording else { return }
        let input = engine.inputNode
        // Removing a tap from a running engine is not synchronous, and a new
        // one installed straight after can find the old one still there —
        // the same uncatchable exception as two starts at once. Stopped first,
        // and only rebuilt at all when the format actually changed; on a
        // first run the notification fires with nothing different.
        let format = input.outputFormat(forBus: 0)
        let formatChanged = format != tapFormat
        do {
            if formatChanged || !engine.isRunning {
                engine.stop()
                try installTap(on: input)
                engine.prepare()
                try engine.start()
            }
        } catch {
            // Now it really has failed: the device went away and nothing can
            // be captured from it.
            Task { @MainActor [weak self] in
                self?.onFailure?(RecorderError.engineFailed(error.localizedDescription))
            }
        }
    }

    private func teardown() {
        isRecording = false
        levelTimer?.invalidate()
        levelTimer = nil
        // Stopped before the tap comes off: removal from a running engine is
        // deferred, and the next start must not find it still there.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        tapFormat = nil
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