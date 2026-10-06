import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// Mic capture at 16 kHz mono Float32 — the format Whisper wants.
///
/// The microphone itself is `InputCapture`'s business. This owns what a
/// recording is: the buffer the words go into, the levels the meter draws,
/// and what happens when the hardware misbehaves partway through. Blocks of
/// audio arrive on the capture's worker thread, which must never touch the
/// main actor — levels are published on a timer instead (§5.2).
public final class AudioRecorder: @unchecked Sendable {

    public enum RecorderError: LocalizedError {
        case converterUnavailable
        case captureFailed(String)
        case captureLost(String)
        case deviceUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Could not convert the input audio to 16 kHz mono."
            case .captureFailed(let reason):
                return "The microphone would not start: \(reason)."
            case .captureLost(let reason):
                return "Recording stopped: \(reason)."
            case .deviceUnavailable(let name):
                return "\(name) is not available."
            }
        }
    }

    public static let sampleRate: Double = 16_000

    /// Called ~30×/s on the main actor with a 0…1 level for the meter.
    @MainActor public var onLevel: ((Float) -> Void)?
    /// Called alongside `onLevel` with the five bars of the meter — see
    /// MeterAnalyzer. Empty once the recording ends.
    @MainActor public var onBands: (([Float]) -> Void)?
    /// Called on the main actor if capture dies mid-recording.
    @MainActor public var onFailure: ((Error) -> Void)?

    /// The microphone, while a recording is running. Made for one recording
    /// and thrown away after it, so nothing about the hardware is remembered
    /// from one to the next. Only ever touched under `captureLock`.
    private var capture: InputCapture?
    private let lock = NSLock()

    /// Serialises every touch of the capture.
    ///
    /// `start()` runs on a background task and takes ~400 ms, most of it in
    /// the hardware. `cancel()` arrives from the main actor whenever the user
    /// presses Esc — and if that lands inside that window, the next key press
    /// starts a second capture while the first is still being set up. One at
    /// a time, always.
    private let captureLock = NSLock()
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
    /// The latest band levels, guarded by `lock`. Analysed on the capture's
    /// worker thread, read by the level timer.
    private var currentBands: [Float] = []
    /// Blocks the microphone has handed over since `start`, guarded by
    /// `lock`. A capture that starts without error and then delivers nothing
    /// looks exactly like one that works until this is read.
    private var bufferCount = 0
    private let meter = MeterAnalyzer()

    /// The microphone `start` was asked for, kept so that a capture rebuilt
    /// partway through a recording can be pointed at it again. Only ever
    /// touched under `captureLock`.
    private var currentDeviceUID: String?

    /// The converter from the capture's blocks to 16 kHz mono, built from the
    /// first block and rebuilt whenever one arrives in a different format.
    /// Touched only on the capture's worker thread, and in `start` before
    /// there is one.
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: sampleRate,
                                                    channels: 1,
                                                    interleaved: false)!

    private var levelTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    public private(set) var isRecording = false

    /// Where the time went in the last `start()`, for latency work. Cheap
    /// enough to always collect: a handful of clock reads.
    public private(set) var startBreakdown: [(phase: String, milliseconds: Double)] = []

    public init() {}

    deinit {
        capture?.stop()
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
        // starts clean.
        lock.lock()
        let cancelsAtEntry = cancelCount
        lock.unlock()

        captureLock.lock()
        defer { captureLock.unlock() }
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
        currentBands = []
        bufferCount = 0
        lock.unlock()
        // A resampler carries a few samples from one call to the next, and
        // those belong to the last recording.
        converter = nil
        converterInput = nil
        lap("buffer")

        currentDeviceUID = deviceUID
        try openCapture(givingUpIfCancelledSince: cancelsAtEntry)
        lap("capture")

        lock.lock()
        let cancelled = cancelCount != cancelsAtEntry
        if !cancelled { isRecording = true }
        lock.unlock()

        if cancelled {
            capture?.stop()
            capture = nil
            throw CancellationError()
        }

        startLevelTimer()
        observeWake()
    }

    /// Stops capture and returns everything recorded, in order.
    @discardableResult
    public func stop() -> [Float] {
        captureLock.lock()
        defer { captureLock.unlock() }
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

        captureLock.lock()
        defer { captureLock.unlock() }
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

    /// How many blocks the microphone has delivered since `start`. Zero a
    /// moment after a start that did not throw means the capture is running
    /// and deaf.
    public var buffersReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferCount
    }

    /// The device the capture is on right now, for the sweep to check
    /// against the one it asked for.
    var captureDeviceID: AudioDeviceID? {
        captureLock.lock()
        defer { captureLock.unlock() }
        return capture?.deviceID
    }

    // MARK: The microphone

    /// How long to wait before each try at opening the microphone, in
    /// milliseconds. A device in the middle of changing — a headset between
    /// its listening profile and its call profile, a display that has just
    /// been plugged in — refuses for a moment and then accepts, and the
    /// difference between an error and a recording is asking again.
    private static let attempts = [0, 150, 400]

    /// Open the microphone `currentDeviceUID` names and start it. Called
    /// under `captureLock`.
    private func openCapture(givingUpIfCancelledSince cancels: Int? = nil) throws {
        var refusal: Error?
        for pause in Self.attempts {
            if pause > 0 {
                Thread.sleep(forTimeInterval: Double(pause) / 1000)
                // Nobody is waiting for this recording any more.
                if let cancels {
                    lock.lock()
                    let cancelled = cancelCount != cancels
                    lock.unlock()
                    if cancelled { throw CancellationError() }
                }
            }

            // Resolved on every try: the id of a device is reassigned when
            // it reconnects, which is one of the things a retry is for.
            var deviceID: AudioDeviceID?
            if let uid = currentDeviceUID {
                deviceID = AudioDevices.device(forUID: uid)?.deviceID
            }
            guard let deviceID = deviceID ?? AudioDevices.defaultInputDeviceID() else {
                throw RecorderError.deviceUnavailable("A microphone")
            }

            do {
                let capture = try InputCapture.open(
                    deviceID: deviceID,
                    onBlock: { [weak self] in self?.append($0) },
                    onDeviceChange: { [weak self] in self?.deviceChanged() })
                try capture.start()
                self.capture = capture
                return
            } catch {
                refusal = error
            }
        }
        throw RecorderError.captureFailed(refusal?.localizedDescription ?? "no reason given")
    }

    /// The device changed its format, or went away, while recording.
    ///
    /// A capture is set up for one format and cannot follow the device to
    /// another, so it is replaced: the same microphone if it is still there,
    /// the system default if it is not. What was recorded so far is kept and
    /// the rest is added to it. Opening a device makes some of them announce
    /// a change that changed nothing, so the capture is asked first.
    private func deviceChanged() {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard isRecording, let capture, !capture.isStillValid else { return }
        replaceCapture()
    }

    /// Called under `captureLock`, while recording.
    private func replaceCapture() {
        capture?.stop()
        capture = nil
        do {
            try openCapture()
        } catch {
            // Now it really has failed: the device went away and nothing can
            // be captured in its place.
            Task { @MainActor [weak self] in self?.onFailure?(error) }
        }
    }

    /// Nothing has arrived for a while, though nothing reported a fault.
    /// Once, the capture is rebuilt, which is what a person would try; twice
    /// in one recording, and it is said out loud rather than left to produce
    /// an empty transcript.
    private func captureWentQuiet(again: Bool) {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard isRecording else { return }
        if again {
            let error = RecorderError.captureLost("the microphone is not delivering any sound")
            Task { @MainActor [weak self] in self?.onFailure?(error) }
        } else {
            replaceCapture()
        }
    }

    // MARK: Stress

    /// Start and stop, over and over, the way a shortcut tapped in a hurry
    /// does — some stops landing while the hardware is still waking, some
    /// after — and report anything that was refused. Every crash report the
    /// app produced while it recorded through AVAudioEngine came from that
    /// pattern, and it could only be reproduced by hand until this existed.
    ///
    ///     CLIO_RECORDER_STRESS=40 Clio.app/Contents/MacOS/Clio
    ///
    /// From the bundle, not `swift run`: only the bundle may use the
    /// microphone. Returns the failures, one line each.
    public static func stress(cycles: Int, deviceUID: String?) async -> [String] {
        let recorder = AudioRecorder()
        var failures: [String] = []
        var seed: UInt32 = 11
        for cycle in 0..<cycles {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let holdMs = Int(seed % 500) + 20          // 20…520 ms held
            let gapMs = Int((seed >> 8) % 300) + 10    // 10…310 ms between
            let starter = Task.detached(priority: .userInitiated) {
                do {
                    try recorder.start(maxSeconds: 5, deviceUID: deviceUID)
                    return "ok"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "FAILED \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(for: .milliseconds(holdMs))
            if cycle % 3 == 2 {
                recorder.cancel()          // a release while it is still waking
            } else {
                _ = await starter.value    // a release after it is live
                recorder.stop()
            }
            let outcome = await starter.value
            if outcome.hasPrefix("FAILED") {
                failures.append("cycle \(cycle) hold \(holdMs)ms: \(outcome)")
            }
            try? await Task.sleep(for: .milliseconds(gapMs))
        }
        return failures
    }

    /// Every microphone on this machine, the system default included, put
    /// through `stress`, then listened to, then switched between.
    ///
    /// Per device, because the failure this was written for is per device. A
    /// microphone whose sample rate differs from the current output device's
    /// could not start at all, and a run against only the selected one
    /// reported no failures on a machine where three inputs out of five were
    /// broken. Each device is named in the result so a failure says which.
    ///
    /// `stress` only asks whether `start` threw. The two passes after it ask
    /// what a user would: does sound arrive, and is it from the microphone
    /// that was picked.
    ///
    /// Only microphones that open quietly, unless `everything` is set: the
    /// rest are a headset that drops into call mode on every start and a
    /// phone that connects and announces it, forty times over, to whoever
    /// is sitting at the machine. The system default is left out too when
    /// it is one of those. Skipped devices are named in the result.
    public static func sweep(cycles: Int, everything: Bool = false) async
        -> (devices: [String], skipped: [String], failures: [String], timings: [String]) {
        let all = AudioDevices.availableInputs()
        let inputs = all.filter { everything || $0.transport.opensQuietly }
        var skipped = all.filter { !inputs.contains($0) }.map(\.name)

        var targets: [(name: String, uid: String?)] = inputs.map { ($0.name, $0.id) }
        if everything || AudioDevices.defaultInput()?.transport.opensQuietly == true {
            targets.insert(("the system default", nil), at: 0)
        } else {
            skipped.insert("the system default", at: 0)
        }

        var failures: [String] = []
        var timings: [String] = []
        for target in targets {
            failures += (await stress(cycles: cycles, deviceUID: target.uid))
                .map { "\(target.name): \($0)" }
            let (timing, failure) = await listen(deviceUID: target.uid)
            if let timing { timings.append("\(target.name): \(timing)") }
            if let failure { failures.append("\(target.name): \(failure)") }
        }
        failures += await switching(between: inputs,
                                    includingDefault: targets.contains { $0.uid == nil })
        return (targets.map(\.name), skipped, failures, timings)
    }

    /// Start once and wait for sound: how long the start took, how long until
    /// the first buffer, and how often they come after that.
    private static func listen(deviceUID: String?) async -> (timing: String?, failure: String?) {
        let recorder = AudioRecorder()
        let clock = ContinuousClock()
        let began = clock.now
        do {
            try await Task.detached { try recorder.start(maxSeconds: 5, deviceUID: deviceUID) }.value
        } catch {
            return (nil, "listen: FAILED \(error.localizedDescription)")
        }
        defer { recorder.stop() }
        let started = clock.now

        // Three seconds: a Bluetooth headset changing into its call profile
        // is the slowest thing here and takes about one.
        var firstBuffer: ContinuousClock.Instant?
        while clock.now - started < .seconds(3) {
            if recorder.buffersReceived > 0 { firstBuffer = clock.now; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let firstBuffer else {
            return (nil, "listen: started, and then delivered nothing for three seconds")
        }

        let countedFrom = recorder.buffersReceived
        try? await Task.sleep(for: .milliseconds(500))
        let perSecond = Double(recorder.buffersReceived - countedFrom) * 2

        func ms(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1000)
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        }
        let cadence = perSecond > 0
            ? "a buffer every \(Int((1000 / perSecond).rounded())) ms"
            : "NO further buffers"
        return ("starts in \(ms(started - began)) ms, first sound "
                + "\(ms(firstBuffer - started)) ms later, then \(cadence)",
                perSecond > 0 ? nil : "listen: one buffer and then nothing")
    }

    /// One recorder, moved from microphone to microphone and back to the
    /// system default, the way the picker in Settings moves it — checking
    /// after every start that the capture is on the device it was asked for.
    ///
    /// A recorder that kept its engine stayed on the last microphone it had
    /// been pointed at when asked to follow the system default again, and
    /// nothing reported it: the start succeeded, on the wrong device.
    private static func switching(between inputs: [AudioInputDevice],
                                  includingDefault: Bool) async -> [String] {
        let recorder = AudioRecorder()
        var failures: [String] = []
        var sequence: [AudioInputDevice?] = []
        if includingDefault {
            sequence.append(nil)
            for device in inputs { sequence += [device, nil] }
        }
        // Twice round, so every microphone is also arrived at from another.
        sequence += inputs + inputs

        for target in sequence {
            let name = target?.name ?? "the system default"
            do {
                try await Task.detached {
                    try recorder.start(maxSeconds: 5, deviceUID: target?.id)
                }.value
            } catch {
                failures.append("switching to \(name): FAILED \(error.localizedDescription)")
                continue
            }
            let wanted = target?.deviceID ?? AudioDevices.defaultInputDeviceID()
            let actual = recorder.captureDeviceID
            if actual != wanted {
                failures.append("switching to \(name): the capture is on device "
                                + "\(actual.map(String.init) ?? "none"), "
                                + "not \(wanted.map(String.init) ?? "none")")
            }
            try? await Task.sleep(for: .milliseconds(150))
            recorder.stop()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return failures
    }

    // MARK: Capture

    /// One block from the microphone, on the capture's worker thread.
    private func append(_ pcmBuffer: AVAudioPCMBuffer) {
        let target = Self.targetFormat
        // Built for the format that is actually arriving, and rebuilt the
        // moment that changes — which, mid-recording, is a device change.
        if converter == nil || converterInput != pcmBuffer.format {
            converter = AVAudioConverter(from: pcmBuffer.format, to: target)
            converterInput = pcmBuffer.format
        }
        guard let converter else { return }

        // The meter reads the hardware buffer, before it is resampled: a
        // 48 kHz frame has the whole voice in it, and the analysis is sized
        // to exactly this buffer.
        let bands: [Float]
        if let channel = pcmBuffer.floatChannelData?[0] {
            let frames = Int(pcmBuffer.frameLength)
            bands = meter.process(
                UnsafeBufferPointer(start: channel, count: frames),
                sampleRate: pcmBuffer.format.sampleRate,
                dt: Float(Double(frames) / pcmBuffer.format.sampleRate))
        } else {
            bands = []
        }

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
        currentBands = bands
        bufferCount += 1
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

    /// How long the microphone may deliver nothing before something is done
    /// about it. Longer than the slowest honest start: a Bluetooth headset
    /// takes a second or two to change profile before its first sound.
    private static let quietLimit: TimeInterval = 4

    private func scheduleLevelTimer() {
        // The recording may already be over: this was queued from `start`,
        // and a stop can reach the main actor first.
        guard isRecording else { return }
        levelTimer?.invalidate()

        let interval = 1.0 / 30.0
        let state = LevelTimerState()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, self.isRecording else {
                timer.invalidate()
                return
            }
            self.lock.lock()
            let rms = self.currentRMS
            let bands = self.currentBands
            let blocks = self.bufferCount
            self.lock.unlock()

            if blocks != state.blocksSeen {
                state.blocksSeen = blocks
                state.lastBlock = Date()
            } else if Date().timeIntervalSince(state.lastBlock) > Self.quietLimit {
                state.lastBlock = Date()
                let again = state.wentQuietBefore
                state.wentQuietBefore = true
                // Off the main actor: rebuilding waits on the hardware.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.captureWentQuiet(again: again)
                }
            }

            // Perceptual, not linear: raw RMS from speech sits so low that a
            // linear bar looks broken. See LevelScaler for the window.
            let level = state.scaler.level(rms: rms, dt: Float(interval))
            Task { @MainActor [weak self] in
                self?.onLevel?(level)
                self?.onBands?(bands)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// What the level timer remembers from one tick to the next. Fresh per
    /// recording, and touched only from that timer on the main run loop, so
    /// it needs no lock.
    private final class LevelTimerState: @unchecked Sendable {
        var scaler = LevelScaler()
        var blocksSeen = 0
        var lastBlock = Date()
        var wentQuietBefore = false
    }

    // MARK: Interruptions

    /// A wake from sleep leaves the hardware in no state to carry on from
    /// (§9), so it ends the session cleanly rather than record silence
    /// forever.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            Task { @MainActor [weak self] in
                self?.onFailure?(RecorderError.captureLost("the Mac woke from sleep"))
            }
        }
    }

    /// Called under `captureLock`.
    private func teardown() {
        isRecording = false
        levelTimer?.invalidate()
        levelTimer = nil
        // Returns once the capture's worker has handed over its last block,
        // so everything that was said is in the buffer before it is read.
        capture?.stop()
        capture = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        Task { @MainActor [weak self] in
            self?.onLevel?(0)
            self?.onBands?([])
        }
    }
}
