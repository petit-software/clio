import Testing
import AVFoundation
import CoreAudio
@testable import ScribeCore

@Suite("Audio devices")
struct AudioDeviceTests {

    @Test("Enumeration finds real input devices with usable identity")
    func enumerationFindsInputs() throws {
        let inputs = AudioDevices.availableInputs()
        // Every Mac this can run on has at least a built-in microphone.
        #expect(!inputs.isEmpty)

        for device in inputs {
            #expect(!device.id.isEmpty)          // the UID we persist
            #expect(!device.name.isEmpty)        // what the menu shows
            #expect(device.deviceID != kAudioObjectUnknown)
            // Only devices that can actually record should be offered.
            #expect(AudioDevices.inputChannelCount(device.deviceID) > 0)
        }
    }

    @Test("UIDs are unique, or the picker cannot tell devices apart")
    func uidsAreUnique() {
        let inputs = AudioDevices.availableInputs()
        #expect(Set(inputs.map(\.id)).count == inputs.count)
    }

    @Test("A device round-trips through its UID")
    func lookupByUID() throws {
        let first = try #require(AudioDevices.availableInputs().first)
        let found = try #require(AudioDevices.device(forUID: first.id))
        #expect(found.id == first.id)
        #expect(found.name == first.name)
    }

    @Test("An unknown UID resolves to nothing rather than a wrong device")
    func unknownUIDIsNil() {
        #expect(AudioDevices.device(forUID: "not-a-real-device-uid") == nil)
    }

    @Test("The built-in microphone is listed first")
    func builtInSortsFirst() {
        let inputs = AudioDevices.availableInputs()
        guard inputs.contains(where: { $0.transport == .builtIn }) else { return }
        #expect(inputs.first?.transport == .builtIn)
    }

    @Test("At most one device claims to be the system default")
    func oneSystemDefault() {
        let defaults = AudioDevices.availableInputs().filter(\.isSystemDefault)
        #expect(defaults.count <= 1)
    }

    @Test("Bluetooth is the transport that carries a warning")
    func onlyBluetoothWarns() {
        #expect(AudioTransport(rawTransport: kAudioDeviceTransportTypeBluetooth)
                    .degradesPlayback)
        #expect(AudioTransport(rawTransport: kAudioDeviceTransportTypeBluetoothLE)
                    .degradesPlayback)
        #expect(AudioTransport(rawTransport: kAudioDeviceTransportTypeBuiltIn)
                    .degradesPlayback == false)
        #expect(AudioTransport(rawTransport: kAudioDeviceTransportTypeUSB)
                    .degradesPlayback == false)
        // An unfamiliar transport must not silently become Bluetooth.
        #expect(AudioTransport(rawTransport: 0x12345678) == .other)
    }

    // MARK: Selection

    @MainActor
    @Test("Nil means follow the system default")
    func nilFollowsSystemDefault() {
        let monitor = AudioDeviceMonitor()
        #expect(monitor.resolved(uid: nil)?.id == monitor.systemDefault?.id)
        #expect(monitor.isMissing(uid: nil) == false)
    }

    @MainActor
    @Test("An attached device resolves to itself")
    func attachedDeviceResolves() throws {
        let monitor = AudioDeviceMonitor()
        let device = try #require(monitor.inputs.first)
        #expect(monitor.resolved(uid: device.id)?.id == device.id)
        #expect(monitor.isMissing(uid: device.id) == false)
    }

    @MainActor
    @Test("An unplugged device is reported missing and falls back")
    func missingDeviceFallsBack() {
        let monitor = AudioDeviceMonitor()
        // Silently recording from the wrong microphone is the failure this
        // guards against.
        #expect(monitor.isMissing(uid: "unplugged-device-uid"))
        #expect(monitor.resolved(uid: "unplugged-device-uid")?.id
                == monitor.systemDefault?.id)
    }

    // MARK: Routing

    /// The claim the whole feature rests on: choosing a microphone actually
    /// points the engine at it. Verified by reading the property back off the
    /// audio unit, not by trusting that the setter returned noErr.
    @Test("Selecting a device really re-points the engine's input")
    func selectionRepointsTheEngine() throws {
        let inputs = AudioDevices.availableInputs()
        try #require(!inputs.isEmpty)

        for device in inputs {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let unit = try #require(input.audioUnit)

            var requested = device.deviceID
            let setStatus = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &requested,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            #expect(setStatus == noErr)

            var actual = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let getStatus = AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &actual, &size)

            #expect(getStatus == noErr)
            #expect(actual == device.deviceID,
                    "\(device.name) did not take: asked for \(device.deviceID), got \(actual)")
        }
    }
}
