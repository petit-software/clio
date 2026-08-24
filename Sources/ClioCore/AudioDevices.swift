import CoreAudio
import Foundation

/// How a microphone is attached, which is worth knowing because it changes the
/// advice we give about it.
public enum AudioTransport: Sendable, Equatable {
    case builtIn
    case usb
    case bluetooth
    case continuityCamera
    case virtual
    case aggregate
    case other

    /// Bluetooth mics are the one case that needs a warning (§9).
    ///
    /// Recording from one forces the link into its bidirectional voice mode,
    /// and everything you are listening to drops to call quality for as long
    /// as the mic is open. Nothing we can fix — but a user who knows can keep
    /// the headset as output and dictate into the built-in mic.
    public var degradesPlayback: Bool { self == .bluetooth }

    public var symbolName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .usb: return "cable.connector"
        case .bluetooth: return "wave.3.right"
        case .continuityCamera: return "iphone"
        case .virtual, .aggregate: return "square.stack.3d.up"
        case .other: return "mic"
        }
    }

    init(rawTransport: UInt32) {
        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuityCamera
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        default: self = .other
        }
    }
}

/// A microphone the user can pick.
///
/// Identified by its CoreAudio UID, not its `AudioDeviceID`: the numeric id is
/// reassigned when a device is unplugged and plugged back in, so persisting it
/// would silently point at the wrong microphone later. The UID is stable.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public var id: String            // the CoreAudio UID
    public var name: String
    public var deviceID: AudioDeviceID
    public var transport: AudioTransport
    public var isSystemDefault: Bool

    public init(id: String, name: String, deviceID: AudioDeviceID,
                transport: AudioTransport, isSystemDefault: Bool) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.transport = transport
        self.isSystemDefault = isSystemDefault
    }
}

/// Reading the machine's audio hardware.
///
/// CoreAudio rather than `AVCaptureDevice`, for two reasons: enumerating here
/// needs no microphone permission, so the picker is populated during
/// onboarding before the user has granted anything; and driving the engine's
/// input needs an `AudioDeviceID`, which this is the layer that has one.
public enum AudioDevices {

    /// Every device with at least one input channel, built-in first.
    public static func availableInputs() -> [AudioInputDevice] {
        let systemDefault = defaultInputDeviceID()

        let devices: [AudioInputDevice] = allDeviceIDs().compactMap { deviceID in
            // Output-only devices report zero input channels; that is what
            // separates a microphone from a pair of speakers.
            guard inputChannelCount(deviceID) > 0,
                  let uid = string(deviceID, kAudioDevicePropertyDeviceUID),
                  let name = string(deviceID, kAudioObjectPropertyName)
            else { return nil }

            return AudioInputDevice(
                id: uid,
                name: name,
                deviceID: deviceID,
                transport: AudioTransport(rawTransport: transportType(deviceID)),
                isSystemDefault: deviceID == systemDefault)
        }

        // Built-in first, then everything else by name: a stable order, so the
        // menu does not reshuffle itself between openings.
        return devices.sorted { left, right in
            if (left.transport == .builtIn) != (right.transport == .builtIn) {
                return left.transport == .builtIn
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    public static func defaultInput() -> AudioInputDevice? {
        guard let id = defaultInputDeviceID() else { return nil }
        return availableInputs().first { $0.deviceID == id }
    }

    /// Resolve a saved UID to a device that is plugged in right now.
    /// Nil means the user's chosen microphone is not attached.
    public static func device(forUID uid: String) -> AudioInputDevice? {
        availableInputs().first { $0.id == uid }
    }

    // MARK: CoreAudio

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }

        // An AudioBufferList is variable length, so it has to be read into raw
        // memory sized by the call above rather than a fixed struct.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value
    }

    static func string(_ deviceID: AudioDeviceID,
                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
