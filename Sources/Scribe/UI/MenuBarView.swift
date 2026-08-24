import SwiftUI
import ScribeCore

/// The system menu: what state we're in, the shortcut, and the few actions
/// worth having without opening Settings.
struct MenuBarView: View {
    @Bindable var coordinator: AppCoordinator
    let openOnboarding: () -> Void

    var body: some View {
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

            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)

            Button("Quit Scribe") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var statusLine: String {
        switch coordinator.state {
        case .idle:
            let key = coordinator.settingsStore.settings.hotkey.displayString
            let mode = coordinator.settingsStore.settings.hotkeyMode
            return mode == .pushToTalk ? "Hold \(key) to dictate" : "Press \(key) to dictate"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .injecting: return "Pasting…"
        case .finished: return "Done"
        case .failed(let message): return message
        }
    }
}

/// The menu bar icon. It has to read at a glance whether we're recording.
struct MenuBarLabel: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
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
                           accessibilityDescription: "Scribe — something went wrong")
                ?? WaveformIcon.resting

        case .idle, .finished, .transcribing, .injecting:
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
