import SwiftUI
import ClioCore

/// The system menu: what state we're in, the shortcut, and the few actions
/// worth having without opening Settings.
public struct MenuBarView: View {
    @Bindable var coordinator: AppCoordinator
    let openOnboarding: () -> Void

    public init(coordinator: AppCoordinator, openOnboarding: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openOnboarding = openOnboarding
    }

    public var body: some View {
        Group {
            Text(statusLine)

            if !coordinator.permissions.allGranted {
                Divider()
                Button("Finish Setup…", action: openOnboarding)
            }

            Divider()

            Button(coordinator.state == .recording ? "Stop Dictation" : "Start Dictation") {
                if coordinator.state == .recording {
                    coordinator.finishRecording()
                } else {
                    coordinator.beginRecording()
                }
            }
            .disabled(coordinator.state.isBusy && coordinator.state != .recording)

            Button("Copy Last Transcript") {
                coordinator.copyLastTranscript()
            }
            .disabled(coordinator.lastTranscript == nil)

            if !coordinator.history.entries.isEmpty {
                Menu("Recent") {
                    // Picking one copies it rather than pasting: the menu has
                    // already taken focus, so the app the text belongs in is
                    // no longer frontmost.
                    ForEach(coordinator.history.entries) { entry in
                        Button(entry.menuLabel) { coordinator.copy(entry) }
                    }
                    Divider()
                    Button("Clear History") { coordinator.history.clear() }
                }
            }

            Divider()

            MicrophoneMenu(coordinator: coordinator)

            Divider()

            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)

            if let updates = coordinator.updates {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
            }

            Button("Quit Clio") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var statusLine: String {
        switch coordinator.state {
        case .idle:
            let key = coordinator.settingsStore.settings.hotkeyDisplayString
            let mode = coordinator.settingsStore.settings.hotkeyMode
            return mode == .pushToTalk ? "Hold \(key) to dictate" : "Press \(key) to dictate"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .injecting: return "Pasting…"
        case .finished: return "Done"
        case .failed(let message): return message
        case .emptyResult(let message): return message
        }
    }
}

/// The microphone picker.
///
/// The shape every other macOS app uses for this: a submenu, a checkmark
/// against the current choice, "System Default" first and named so the user
/// can see what it currently means.
struct MicrophoneMenu: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Menu(title) {
            Button {
                coordinator.selectInputDevice(uid: nil)
            } label: {
                Label(defaultTitle, systemImage: check(for: nil))
            }

            if !coordinator.audioDevices.inputs.isEmpty {
                Divider()
            }

            ForEach(coordinator.audioDevices.inputs) { device in
                Button {
                    coordinator.selectInputDevice(uid: device.id)
                } label: {
                    Label(name(for: device), systemImage: check(for: device.id))
                }
            }

            // A microphone that was chosen and then unplugged stays visible,
            // ticked, and obviously unavailable. Dropping it silently would
            // leave the user believing they are recording from it.
            if coordinator.selectedInputIsMissing, let missing = coordinator.selectedInputUID {
                Divider()
                Button {} label: {
                    Label("\(shortName(missing)) (not connected)",
                          systemImage: "exclamationmark.triangle")
                }
                .disabled(true)
            }
        }
    }

    private var title: String {
        coordinator.selectedInputIsMissing ? "Microphone ⚠" : "Microphone"
    }

    private var defaultTitle: String {
        guard let systemDefault = coordinator.audioDevices.systemDefault else {
            return "System Default"
        }
        return "System Default (\(systemDefault.name))"
    }

    private func name(for device: AudioInputDevice) -> String {
        // The one warning the spec asks the picker to carry (§9): recording
        // from a Bluetooth mic drops everything you are listening to to call
        // quality, for as long as the mic is open.
        device.transport.degradesPlayback
            ? "\(device.name) — lowers audio quality"
            : device.name
    }

    /// SwiftUI menus have no checkmark of their own, so the row's icon is it.
    /// An empty-looking symbol keeps the labels aligned in a proportional menu.
    private func check(for uid: String?) -> String {
        coordinator.selectedInputUID == uid ? "checkmark" : "circle.dotted"
    }

    /// A UID we can no longer look up — show the tail, which is usually the
    /// readable part, rather than the whole CoreAudio string.
    private func shortName(_ uid: String) -> String {
        uid.split(separator: ":").last.map(String.init) ?? uid
    }
}

/// The menu bar icon. It has to read at a glance whether we're recording.
public struct MenuBarLabel: View {
    @Bindable var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    public var body: some View {
        Image(nsImage: icon)
            // The NSImage is already a template; saying so again costs nothing
            // and keeps the tinting right if the image is ever swapped.
            .renderingMode(.template)
    }

    private var icon: NSImage {
        switch coordinator.state {
        case .recording:
            // The mark itself becomes the level meter — same silhouette,
            // moving. Quantised and cached inside WaveformIcon, so a steady
            // voice does not redraw the menu bar 30 times a second.
            return WaveformIcon.live(level: coordinator.inputLevel)

        case .failed:
            // The one state that earns a different glyph: something is wrong
            // and the mark alone cannot say so.
            return NSImage(systemSymbolName: "exclamationmark.triangle",
                           accessibilityDescription: "Clio — something went wrong")
                ?? WaveformIcon.resting

        case .idle, .finished, .transcribing, .injecting, .emptyResult:
            // emptyResult belongs here, not with .failed. Nothing is wrong —
            // the user pressed the key and said nothing — and a warning in the
            // menu bar would send them hunting for a fault.
            // Transcribing keeps the resting mark rather than a third pose:
            // it is usually sub-second, and a flicker in the menu bar reads as
            // a glitch. The overlay is what reports progress.
            //
            // Dimmed when we cannot actually hear the shortcut — more useful
            // than a "ready" icon that is lying.
            return coordinator.permissions.allGranted
                ? WaveformIcon.resting
                : WaveformIcon.muted
        }
    }
}
