import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// One microphone, opened directly.
///
/// This is the AUHAL unit with its output half switched off — the thing
/// `AVAudioEngine` wraps, without the engine. The engine was the source of
/// every way capture has ever failed here:
///
/// - Its input and output nodes are one unit, so a recording depended on the
///   *output* device. A microphone at one sample rate and headphones at
///   another would not start (-10868), and headphones changing their format
///   while a recording ran — a Bluetooth headset going into call mode, for
///   any app's sake — raised inside the engine's own IO thread, where nothing
///   of ours is on the stack to catch it.
/// - It reports misuse as NSExceptions rather than errors.
/// - It caches formats, so one kept between recordings went stale whenever
///   the hardware changed in between, and one pointed at a microphone stayed
///   on it when asked to follow the system default again.
///
/// Here the output device is not involved at all, every call returns a
/// status, and a capture is built for one recording and thrown away.
///
/// The IO thread does the least it can: render, copy into a ring, signal.
/// A worker thread takes it from there in blocks of `blockFrames`, which is
/// the size the meter's analysis is written for, whatever size the hardware
/// happens to deliver in.
final class InputCapture: @unchecked Sendable {

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus

        var errorDescription: String? { "\(step) failed (error \(status))" }
    }

    static let blockFrames = 1024

    let deviceID: AudioDeviceID
    /// What the blocks handed to `onBlock` are in: the device's own sample
    /// rate, float, deinterleaved.
    let format: AVAudioFormat

    /// Called on the worker thread with each block. The buffer is reused;
    /// take what is needed from it before returning.
    private let onBlock: @Sendable (AVAudioPCMBuffer) -> Void
    /// Called, on a queue of its own, when the device's format moves or the
    /// device goes away. The capture is useless from then on.
    private let onDeviceChange: @Sendable () -> Void

    private let unit: AudioUnit
    private let hardware: AudioStreamBasicDescription

    /// Rendered into on the IO thread, and never touched anywhere else.
    private let scratch: AVAudioPCMBuffer
    /// Filled and handed out on the worker thread.
    private let block: AVAudioPCMBuffer

    /// About a second of audio per channel. Guarded by `ringLock`, along
    /// with the two indices and `isFinishing`.
    private let ring: [UnsafeMutablePointer<Float>]
    private let ringCapacity: Int
    private var readIndex = 0
    private var available = 0
    private var isFinishing = false
    private let ringLock = OSAllocatedUnfairLock()

    private let wake = DispatchSemaphore(value: 0)
    private let workerDone = DispatchSemaphore(value: 0)

    private enum Phase { case configured, running, stopped }
    private var phase = Phase.configured
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let listenerQueue = DispatchQueue(label: "com.bartbak.clio.capture.listener")
    private static let changeQueue = DispatchQueue(label: "com.bartbak.clio.capture.change")

    // MARK: Opening

    /// Build a unit for this device and set it up as far as it can go
    /// without starting. Throws a `Failure` naming the step that refused.
    static func open(deviceID: AudioDeviceID,
                     onBlock: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                     onDeviceChange: @escaping @Sendable () -> Void) throws -> InputCapture {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure(step: "finding the system's input unit", status: -1)
        }
        var instance: AudioUnit?
        let created = AudioComponentInstanceNew(component, &instance)
        guard created == noErr, let unit = instance else {
            throw Failure(step: "creating an input unit", status: created)
        }

        do {
            // Input on, output off: element 1 is the microphone, element 0
            // the speakers. With output off the unit never opens an output
            // device, which is the whole point of not using the engine.
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flag = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &on, flag),
                      "enabling input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &off, flag),
                      "switching output off")

            var device = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &device,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)),
                      "selecting it")

            // What the device delivers. The unit does not resample input,
            // so the format asked of it has to be at this rate.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 1, &hardware, &size),
                      "reading its format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
                throw Failure(step: "getting a usable format from it", status: 0)
            }

            // One or two channels are taken as they are and mixed down later.
            // More than two is an interface with a microphone on its first
            // input and who knows what on the rest, so only that one is taken.
            let channels: UInt32 = hardware.mChannelsPerFrame > 2 ? 1 : hardware.mChannelsPerFrame
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: hardware.mSampleRate,
                                             channels: channels,
                                             interleaved: false)
            else { throw Failure(step: "describing its format", status: 0) }

            if channels != hardware.mChannelsPerFrame {
                var map: [Int32] = [0]
                try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap,
                                               kAudioUnitScope_Output, 1, &map,
                                               UInt32(MemoryLayout<Int32>.size)),
                          "choosing its first channel")
            }

            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 1, &client, size),
                      "setting the capture format")

            guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
                  let block = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(blockFrames))
            else { throw Failure(step: "allocating buffers", status: 0) }

            return InputCapture(deviceID: deviceID, unit: unit, hardware: hardware,
                                format: format, scratch: scratch, block: block,
                                onBlock: onBlock, onDeviceChange: onDeviceChange)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private init(deviceID: AudioDeviceID, unit: AudioUnit,
                 hardware: AudioStreamBasicDescription, format: AVAudioFormat,
                 scratch: AVAudioPCMBuffer, block: AVAudioPCMBuffer,
                 onBlock: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                 onDeviceChange: @escaping @Sendable () -> Void) {
        self.deviceID = deviceID
        self.unit = unit
        self.hardware = hardware
        self.format = format
        self.scratch = scratch
        self.block = block
        self.onBlock = onBlock
        self.onDeviceChange = onDeviceChange

        let capacity = max(Int(format.sampleRate), 4 * Self.blockFrames)
        ringCapacity = capacity
        ring = (0..<Int(format.channelCount)).map { _ in
            let channel = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            channel.initialize(repeating: 0, count: capacity)
            return channel
        }
    }

    deinit {
        stop()
        for channel in ring { channel.deallocate() }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    // MARK: Running

    /// Start delivering blocks. Call once; a capture that has been stopped
    /// is finished with.
    func start() throws {
        guard phase == .configured else { return }

        var callback = AURenderCallbackStruct(
            inputProc: inputCaptureRender,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                            kAudioUnitScope_Global, 0, &callback,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                       "attaching to it")
        try Self.check(AudioUnitInitialize(unit), "preparing it")

        let worker = Thread { [self] in work() }
        worker.name = "Clio capture"
        worker.qualityOfService = .userInteractive
        worker.start()
        phase = .running

        let started = AudioOutputUnitStart(unit)
        guard started == noErr else {
            stop()
            throw Failure(step: "starting it", status: started)
        }
        watchDevice()
    }

    /// Stop, hand over whatever is left in the ring as one last short block,
    /// and let go of the device. Returns once the worker has finished, so
    /// nothing calls `onBlock` afterwards.
    func stop() {
        switch phase {
        case .stopped:
            return
        case .configured:
            phase = .stopped
            AudioComponentInstanceDispose(unit)
            return
        case .running:
            phase = .stopped
        }

        for (address, listener) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address,
                                                   Self.listenerQueue, listener)
        }
        listeners = []

        // Synchronous: no render callback is in flight once this returns.
        AudioOutputUnitStop(unit)

        ringLock.lock()
        isFinishing = true
        ringLock.unlock()
        wake.signal()
        workerDone.wait()

        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// False once the device has gone, or has changed the rate or the
    /// number of channels it delivers since this capture was set up for it.
    var isStillValid: Bool {
        guard phase == .running else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr,
              alive != 0
        else { return false }

        var now = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 1, &now, &size) == noErr
        else { return false }
        return now.mSampleRate == hardware.mSampleRate
            && now.mChannelsPerFrame == hardware.mChannelsPerFrame
    }

    // MARK: The IO thread

    /// The unit has `frames` of input ready. Realtime: no allocation, and the
    /// lock is only ever held for a copy.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timeStamp: UnsafePointer<AudioTimeStamp>,
                            _ frames: UInt32) -> OSStatus {
        guard frames <= scratch.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        scratch.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames,
                                     scratch.mutableAudioBufferList)
        guard status == noErr, let channels = scratch.floatChannelData else { return status }

        ringLock.lock()
        // A full ring means the worker has been stuck for a second. The
        // newest audio is dropped rather than the oldest overwritten, so
        // what is kept stays in order.
        let count = min(Int(frames), ringCapacity - available)
        let writeIndex = (readIndex + available) % ringCapacity
        let first = min(count, ringCapacity - writeIndex)
        for channel in 0..<ring.count {
            (ring[channel] + writeIndex).update(from: channels[channel], count: first)
            if count > first {
                ring[channel].update(from: channels[channel] + first, count: count - first)
            }
        }
        available += count
        ringLock.unlock()

        wake.signal()
        return noErr
    }

    // MARK: The worker thread

    private func work() {
        var finished = false
        while !finished {
            wake.wait()
            while true {
                ringLock.lock()
                let finishing = isFinishing
                let count = available >= Self.blockFrames
                    ? Self.blockFrames
                    : (finishing ? available : 0)
                if count > 0, let channels = block.floatChannelData {
                    let first = min(count, ringCapacity - readIndex)
                    for channel in 0..<ring.count {
                        channels[channel].update(from: ring[channel] + readIndex, count: first)
                        if count > first {
                            (channels[channel] + first).update(from: ring[channel],
                                                               count: count - first)
                        }
                    }
                    readIndex = (readIndex + count) % ringCapacity
                    available -= count
                }
                ringLock.unlock()

                guard count > 0 else {
                    finished = finishing
                    break
                }
                block.frameLength = AVAudioFrameCount(count)
                onBlock(block)
            }
        }
        workerDone.signal()
    }

    // MARK: The device changing underneath

    private func watchDevice() {
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        // Hopped onto a second queue before anything is done about it: what
        // is done about it is stopping this capture, which removes these
        // listeners, and that must not be waited for on the queue they run on.
        let changed = onDeviceChange
        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope,
                mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Self.changeQueue.async { changed() }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address,
                                                   Self.listenerQueue, listener) == noErr {
                listeners.append((address, listener))
            }
        }
    }
}

/// The unit's input callback. A function at file scope and not a closure,
/// because it is called as a C function pointer on the IO thread.
private func inputCaptureRender(refCon: UnsafeMutableRawPointer,
                                flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                timeStamp: UnsafePointer<AudioTimeStamp>,
                                bus: UInt32,
                                frames: UInt32,
                                data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<InputCapture>.fromOpaque(refCon).takeUnretainedValue()
        .render(flags, timeStamp, frames)
}
