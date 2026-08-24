import CoreAudio
import Foundation
import Observation

/// Keeps the microphone list current.
///
/// Devices come and go while the app runs — a headset connects, a display is
/// unplugged, someone picks up their iPhone. A list read once at launch is
/// wrong within minutes, so this listens to CoreAudio rather than polling.
@MainActor
@Observable
public final class AudioDeviceMonitor {

    public private(set) var inputs: [AudioInputDevice] = []
    /// What "System Default" currently resolves to, so the menu can name it
    /// instead of making the user guess.
    public private(set) var systemDefault: AudioInputDevice?

    /// Held rather than tracked inline because a `@MainActor` class has a
    /// nonisolated `deinit`, which cannot touch this object's own properties.
    /// Giving the registrations their own lifetime keeps the teardown honest:
    /// CoreAudio will happily call a listener belonging to a deallocated
    /// object, so unregistering is not optional.
    private let registry = ListenerRegistry()

    public init() {
        refresh()
        startListening()
    }

    public func refresh() {
        inputs = AudioDevices.availableInputs()
        systemDefault = inputs.first { $0.isSystemDefault }
    }

    /// The device a given setting resolves to right now.
    ///
    /// Nil for "follow the system default", which is also what a saved device
    /// that is no longer attached falls back to.
    public func resolved(uid: String?) -> AudioInputDevice? {
        guard let uid else { return systemDefault }
        return inputs.first { $0.id == uid } ?? systemDefault
    }

    /// True when the user picked a microphone that is not currently attached.
    /// Worth saying out loud rather than silently recording from something else.
    public func isMissing(uid: String?) -> Bool {
        guard let uid else { return false }
        return !inputs.contains { $0.id == uid }
    }

    // MARK: Hardware notifications

    private func startListening() {
        // The device list itself, and which one is the default — the second
        // changes without the first when the user switches in System Settings.
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice] {
            let address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // CoreAudio calls this on its own queue.
                Task { @MainActor in self?.refresh() }
            }

            var mutableAddress = address
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &mutableAddress, DispatchQueue.main, block)

            if status == noErr {
                registry.add(address: address, block: block)
            }
        }
    }
}

/// Owns the CoreAudio listener registrations and removes them when it dies.
private final class ListenerRegistry: @unchecked Sendable {
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func add(address: AudioObjectPropertyAddress,
             block: @escaping AudioObjectPropertyListenerBlock) {
        listeners.append((address, block))
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        }
    }
}
