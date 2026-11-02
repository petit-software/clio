import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Everything the Mac plays — the other side of a call — through a Core
/// Audio process tap.
///
/// Not ScreenCaptureKit. That records a display to get at its audio, so it
/// needs Screen Recording, a far larger permission than hearing the call; a
/// tap needs only the system-audio one (`NSAudioCaptureUsageDescription`).
///
/// The tap hears every process except Clio, mixed to stereo. It is wired
/// into a private aggregate device whose clock is the current output device
/// — Apple's own recipe — and read with an IOProc. The aggregate is
/// invisible to every other app and is destroyed with the capture.
///
/// Like `InputCapture`, one of these is made for one stretch of listening
/// and thrown away: when the output device changes, the aggregate's clock
/// has gone, and `SystemAudioRecorder` builds a new one.
///
/// The IO thread renders into a ring and signals; a worker thread mixes to
/// mono, resamples to 16 kHz and hands the samples on. If the user has not
/// allowed system audio recording, macOS does not refuse — the tap delivers
/// silence. `hasHeardSound` is how that is told apart from a quiet call.
@available(macOS 14.2, *)
final class SystemAudioCapture: @unchecked Sendable {

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus

        var errorDescription: String? { "\(step) failed (error \(status))" }
    }

    /// The output device the aggregate is clocked by, so a change can be
    /// recognised.
    let outputDeviceID: AudioDeviceID

    private let tapID: AudioObjectID
    private let aggregateID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    /// The tap's own rate.
    private let sampleRate: Double

    private let onSamples: @Sendable ([Float]) -> Void

    // The ring: mono, at the tap's rate. Written on the IO thread, read on
    // the worker; guarded by `ringLock` with the indices and `isFinishing`.
    private let ring: UnsafeMutablePointer<Float>
    private let ringCapacity: Int
    private var writeIndex = 0
    private var available = 0
    private var isFinishing = false
    private var heardSound = false
    private let ringLock = OSAllocatedUnfairLock()

    private let wake = DispatchSemaphore(value: 0)
    private let workerDone = DispatchSemaphore(value: 0)
    private var isRunning = false

    private static let blockFrames = 1024
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: AudioRecorder.sampleRate,
                                                    channels: 1, interleaved: false)!

    // MARK: Opening

    /// Create the tap and the aggregate around it, ready to start. Throws a
    /// `Failure` naming the step that refused; anything made before it is
    /// destroyed again.
    static func open(onSamples: @escaping @Sendable ([Float]) -> Void) throws -> SystemAudioCapture {
        guard let output = AudioDevices.defaultOutputDeviceID(),
              let outputUID = AudioDevices.uid(of: output) else {
            throw Failure(step: "finding the output device", status: -1)
        }

        // Clio's own sounds are not part of the meeting.
        let ownProcess = processObject(for: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Clio meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "creating the tap")

        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
                      "reading the tap's format")
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mSampleRate > 0 else {
                throw Failure(step: "reading the tap's format", status: -1)
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Clio Meeting",
                kAudioAggregateDeviceUIDKey: "com.bartbak.clio.meeting.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapDriftCompensationKey: true,
                     kAudioSubTapUIDKey: description.uuid.uuidString],
                ],
            ]
            var aggregateID = AudioDeviceID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "creating the listening device")

            return SystemAudioCapture(tapID: tapID, aggregateID: aggregateID,
                                      outputDeviceID: output,
                                      sampleRate: format.mSampleRate,
                                      onSamples: onSamples)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    private init(tapID: AudioObjectID, aggregateID: AudioDeviceID,
                 outputDeviceID: AudioDeviceID, sampleRate: Double,
                 onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.outputDeviceID = outputDeviceID
        self.sampleRate = sampleRate
        self.onSamples = onSamples
        ringCapacity = max(Int(sampleRate) * 2, 8 * Self.blockFrames)
        ring = .allocate(capacity: ringCapacity)
        ring.initialize(repeating: 0, count: ringCapacity)
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        ring.deallocate()
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    /// The Core Audio object for a process, or nil if it has not used audio.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    // MARK: Running

    func start() throws {
        guard !isRunning else { return }
        var proc: AudioDeviceIOProcID?
        try Self.check(
            AudioDeviceCreateIOProcID(aggregateID, systemAudioCaptureIO,
                                      Unmanaged.passUnretained(self).toOpaque(), &proc),
            "attaching to the listening device")
        procID = proc

        let worker = Thread { [self] in work() }
        worker.name = "Clio system audio"
        worker.qualityOfService = .userInitiated
        worker.start()
        isRunning = true

        let started = AudioDeviceStart(aggregateID, proc)
        guard started == noErr else {
            stop()
            throw Failure(step: "starting to listen", status: started)
        }
    }

    /// Stop, hand over what is left, and return once nothing more will be.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let procID {
            // Synchronous: no IO callback is in flight once this returns.
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        ringLock.lock()
        isFinishing = true
        ringLock.unlock()
        wake.signal()
        workerDone.wait()
    }

    /// Whether anything louder than digital silence has arrived. A denied
    /// permission produces exact zeros, which no real output does for long.
    var hasHeardSound: Bool {
        ringLock.lock()
        defer { ringLock.unlock() }
        return heardSound
    }

    // MARK: The IO thread

    /// Mix whatever arrived to mono and copy it into the ring. Realtime: no
    /// allocation, the lock held only for the copy.
    fileprivate func io(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }

        let channelsInFirst = Int(max(first.mNumberChannels, 1))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channelsInFirst
        guard frames > 0 else { return }

        ringLock.lock()
        defer { ringLock.unlock() }
        // Full: drop the oldest, as a meeting would rather lose a moment of
        // audio than stall the device.
        if available + frames > ringCapacity {
            available = max(0, ringCapacity - frames)
        }
        var sound = false
        if buffers.count == 1 {
            // Interleaved: one buffer, every channel in it.
            let samples = firstData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelsInFirst {
                    sum += samples[frame * channelsInFirst + channel]
                }
                let value = sum / Float(channelsInFirst)
                if value != 0 { sound = true }
                ring[(writeIndex + frame) % ringCapacity] = value
            }
        } else {
            // Deinterleaved: a buffer per channel.
            let channelCount = Float(buffers.count)
            for frame in 0..<frames {
                var sum: Float = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    sum += data.assumingMemoryBound(to: Float.self)[frame]
                }
                let value = sum / channelCount
                if value != 0 { sound = true }
                ring[(writeIndex + frame) % ringCapacity] = value
            }
        }
        if sound { heardSound = true }
        writeIndex = (writeIndex + frames) % ringCapacity
        available += frames
        wake.signal()
    }

    // MARK: The worker thread

    private func work() {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate, channels: 1,
                                        interleaved: false)!
        let block = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                     frameCapacity: AVAudioFrameCount(Self.blockFrames))!
        let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        var finished = false
        while !finished {
            wake.wait()
            while true {
                ringLock.lock()
                let finishing = isFinishing
                let count = available >= Self.blockFrames
                    ? Self.blockFrames
                    : (finishing ? available : 0)
                if count > 0, let channel = block.floatChannelData?[0] {
                    let readIndex = (writeIndex - available + ringCapacity) % ringCapacity
                    for i in 0..<count {
                        channel[i] = ring[(readIndex + i) % ringCapacity]
                    }
                    available -= count
                }
                ringLock.unlock()

                guard count > 0 else {
                    finished = finishing
                    break
                }
                block.frameLength = AVAudioFrameCount(count)
                if let converter, let samples = Self.convert(block, with: converter) {
                    onSamples(samples)
                }
            }
        }
        workerDone.signal()
    }

    private static func convert(_ block: AVAudioPCMBuffer,
                                with converter: AVAudioConverter) -> [Float]? {
        let ratio = targetFormat.sampleRate / block.format.sampleRate
        let capacity = AVAudioFrameCount(Double(block.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) let source = block
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
        guard error == nil, let data = converted.floatChannelData?[0],
              converted.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
    }
}

/// The aggregate device's IOProc. A function at file scope and not a
/// closure, because it is called as a C function pointer on the IO thread —
/// see the event tap's trap in AGENTS.md.
@available(macOS 14.2, *)
private func systemAudioCaptureIO(device: AudioObjectID,
                                  now: UnsafePointer<AudioTimeStamp>,
                                  input: UnsafePointer<AudioBufferList>,
                                  inputTime: UnsafePointer<AudioTimeStamp>,
                                  output: UnsafeMutablePointer<AudioBufferList>,
                                  outputTime: UnsafePointer<AudioTimeStamp>,
                                  refCon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let refCon else { return noErr }
    Unmanaged<SystemAudioCapture>.fromOpaque(refCon).takeUnretainedValue().io(input)
    return noErr
}

// MARK: - The recorder

/// System audio for the length of a meeting: a `SystemAudioCapture`, rebuilt
/// when the output device changes underneath it (headphones plugged in, a
/// headset connecting), since its clock is that device.
public final class SystemAudioRecorder: @unchecked Sendable {

    /// Whether this Mac can tap system audio at all (macOS 14.2 and later).
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Called on a worker thread with 16 kHz mono samples.
    public var onSamples: (@Sendable ([Float]) -> Void)?

    private let lock = NSLock()
    private var capture: AnyObject?
    private var listener: AudioObjectPropertyListenerBlock?
    private var heardBeforeRebuild = false
    private static let listenerQueue = DispatchQueue(label: "com.bartbak.clio.system-audio.listener")

    public struct Unsupported: LocalizedError {
        public var errorDescription: String? {
            "Hearing the other side of a call needs macOS 14.2 or later."
        }
    }

    public init() {}

    deinit { stop() }

    public func start() throws {
        guard #available(macOS 14.2, *) else {
            throw Unsupported()
        }
        lock.lock()
        defer { lock.unlock() }
        guard capture == nil else { return }
        try openCapture()
        watchOutputDevice()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let listener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, Self.listenerQueue, listener)
            self.listener = nil
        }
        if #available(macOS 14.2, *), let capture = capture as? SystemAudioCapture {
            heardBeforeRebuild = heardBeforeRebuild || capture.hasHeardSound
            capture.stop()
        }
        capture = nil
    }

    /// Whether anything but silence has come through since `start`.
    public var hasHeardSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        if #available(macOS 14.2, *), let capture = capture as? SystemAudioCapture {
            return heardBeforeRebuild || capture.hasHeardSound
        }
        return heardBeforeRebuild
    }

    /// Called under `lock`.
    @available(macOS 14.2, *)
    private func openCapture() throws {
        let forward: @Sendable ([Float]) -> Void = { [weak self] samples in
            self?.onSamples?(samples)
        }
        let capture = try SystemAudioCapture.open(onSamples: forward)
        try capture.start()
        self.capture = capture
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Called under `lock`.
    private func watchOutputDevice() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.outputDeviceChanged()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, Self.listenerQueue, listener) == noErr {
            self.listener = listener
        }
    }

    private func outputDeviceChanged() {
        guard #available(macOS 14.2, *) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let current = capture as? SystemAudioCapture,
              current.outputDeviceID != AudioDevices.defaultOutputDeviceID() else { return }
        heardBeforeRebuild = heardBeforeRebuild || current.hasHeardSound
        current.stop()
        capture = nil
        // A failure here leaves the meeting with the microphone alone, which
        // is better than ending it; the next output change tries again.
        try? openCapture()
    }
}

// MARK: - Checking it

extension SystemAudioRecorder {
    /// Listens for `seconds` and says what came through: how much audio,
    /// how loud, and whether any of it was more than silence. Optionally
    /// writes it to a WAV to be listened to.
    ///
    ///     say -v Samantha "testing the meeting tap" &
    ///     CLIO_SYSTEM_AUDIO_TEST=5 Clio.app/Contents/MacOS/Clio
    ///
    /// From the bundle: the permission belongs to it, and the first run is
    /// what makes macOS ask.
    public static func check(seconds: Double, writingTo url: URL?) async -> String {
        let recorder = SystemAudioRecorder()
        let collected = Collected()
        recorder.onSamples = { collected.append($0) }
        do {
            try recorder.start()
        } catch {
            return "[system audio] FAILED to start: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(seconds))
        recorder.stop()
        let samples = collected.samples
        let peak = samples.map(abs).max() ?? 0
        if let url {
            try? AudioWAV.data(samples).write(to: url)
        }
        return String(format: "[system audio] %.1f s received, peak %.3f, heard sound: %@%@",
                      Double(samples.count) / AudioRecorder.sampleRate, peak,
                      recorder.hasHeardSound ? "yes" : "NO",
                      url.map { ", written to \($0.path)" } ?? "")
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [Float] = []
        func append(_ samples: [Float]) { lock.lock(); buffer += samples; lock.unlock() }
        var samples: [Float] { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}

/// 16 kHz mono 16-bit WAV, for listening to what a capture heard.
enum AudioWAV {
    static func data(_ samples: [Float], sampleRate: Int = Int(AudioRecorder.sampleRate)) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
