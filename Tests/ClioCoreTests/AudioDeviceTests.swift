import Testing
import AVFoundation
import CoreAudio
@testable import ClioCore

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
    /// opens that microphone. Set up for each one — not started, which
    /// would need the permission a test run does not have — and asked what
    /// it ended up on and in what format.
    ///
    /// Only the quiet ones. Setting up a capture for a Bluetooth headset or
    /// an iPhone is enough to make it notice.
    @Test("A capture opens on the microphone it was asked for")
    func captureOpensOnTheChosenDevice() throws {
        let inputs = AudioDevices.availableInputs().filter(\.transport.opensQuietly)
        try #require(!inputs.isEmpty)

        for device in inputs {
            let capture = try InputCapture.open(deviceID: device.deviceID,
                                                onBlock: { _ in },
                                                onDeviceChange: {})
            defer { capture.stop() }
            #expect(capture.deviceID == device.deviceID)
            #expect(capture.format.sampleRate > 0, "\(device.name) reported no sample rate")
            // More than two channels is cut to the first, so never more.
            #expect((1...2).contains(capture.format.channelCount))
        }
    }

    @Test("A device that does not exist is an error, not a crash")
    func captureRefusesAnUnknownDevice() {
        #expect(throws: InputCapture.Failure.self) {
            _ = try InputCapture.open(deviceID: 0xFFFF_FFF0,
                                      onBlock: { _ in }, onDeviceChange: {})
        }
    }

    // MARK: Which microphones may be opened unasked

    @Test("Only built-in and USB microphones open without anyone noticing")
    func quietTransports() {
        #expect(AudioTransport.builtIn.opensQuietly)
        #expect(AudioTransport.usb.opensQuietly)
        // A headset drops into call mode; a phone connects and says so.
        #expect(!AudioTransport.bluetooth.opensQuietly)
        #expect(!AudioTransport.continuityCamera.opensQuietly)
        // And anything unrecognised is assumed to be noticed.
        #expect(!AudioTransport.other.opensQuietly)
        #expect(!AudioTransport.virtual.opensQuietly)
        #expect(!AudioTransport.aggregate.opensQuietly)
    }

    @Test("Another process's private default device is not a microphone")
    func processAggregatesAreNotListed() {
        #expect(AudioDevices.isProcessDefaultAggregate(uid: "CADefaultDeviceAggregate-90828-0"))
        #expect(!AudioDevices.isProcessDefaultAggregate(uid: "BuiltInMicrophoneDevice"))
        #expect(!AudioDevices.availableInputs().contains {
            $0.id.hasPrefix("CADefaultDeviceAggregate")
        })
    }

    @Test("A stored choice of that private device means the system default")
    func storedProcessAggregateIsDropped() throws {
        let stored = Data(#"{"inputDeviceUID":"CADefaultDeviceAggregate-90527-0"}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: stored).inputDeviceUID == nil)

        let real = Data(#"{"inputDeviceUID":"BuiltInMicrophoneDevice"}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: real).inputDeviceUID
                == "BuiltInMicrophoneDevice")
    }
}
