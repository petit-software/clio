import SwiftUI
import ScribeCore

/// The permission walkthrough (§7).
///
/// Microphone first because it prompts inline; Accessibility second because it
/// cannot be granted programmatically — the user has to visit System Settings,
/// and the only honest thing to do is deep-link there and wait.
struct OnboardingView: View {
    @Bindable var coordinator: AppCoordinator
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Scribe")
                    .font(.title2.weight(.semibold))
                Text("Dictation that never leaves your Mac. Two permissions and "
                     + "you're set.")
                    .foregroundStyle(.secondary)
            }

            step(number: 1,
                 title: "Microphone",
                 detail: "So Scribe can hear you. Audio is transcribed on "
                       + "device and never uploaded.",
                 state: coordinator.permissions.microphone,
                 primary: "Allow Microphone",
                 action: { Task { await coordinator.permissions.requestMicrophone() } },
                 fallback: coordinator.permissions.openMicrophoneSettings)

            step(number: 2,
                 title: "Accessibility",
                 detail: "So Scribe can see its shortcut and paste into the "
                       + "app you're typing in. macOS requires you to grant this "
                       + "in System Settings.",
                 state: coordinator.permissions.accessibility,
                 primary: "Open System Settings",
                 action: coordinator.permissions.requestAccessibility,
                 fallback: coordinator.permissions.openAccessibilitySettings)

            Spacer(minLength: 0)

            HStack {
                if coordinator.permissions.allGranted {
                    Label("All set — hold \(hotkeyLabel) to dictate.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(coordinator.permissions.allGranted ? "Done" : "Skip for now",
                       action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 420)
        .onAppear { coordinator.permissions.beginPolling() }
    }

    private var hotkeyLabel: String {
        coordinator.settingsStore.settings.hotkey.displayString
    }

    @ViewBuilder
    private func step(number: Int,
                      title: String,
                      detail: String,
                      state: PermissionState,
                      primary: String,
                      action: @escaping () -> Void,
                      fallback: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.isGranted ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 24, height: 24)
                if state.isGranted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !state.isGranted {
                    Button(primary) {
                        // Once macOS has recorded a denial it ignores the API
                        // request, so a denied state goes straight to Settings.
                        state == .notDetermined ? action() : fallback()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
