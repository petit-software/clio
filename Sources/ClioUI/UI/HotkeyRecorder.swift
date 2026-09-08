import AppKit
import Carbon.HIToolbox
import SwiftUI
import ClioCore

/// Records the next chord the user presses.
///
/// Keys are collected as they go down and the chord is committed when the
/// first of them comes back up, or when it reaches `Hotkey.maxKeys` — so
/// holding ⌃ and pressing A then S records ⌃A+S. Modifiers alone are
/// committed when they are released, not pressed: the ⌃ held on the way to
/// a key is not a chord in itself.
///
/// A local NSEvent monitor is enough here — the window it sits in is focused
/// when it's in use, so this does not need the global tap.
///
/// Its own file because it is used twice: Settings ▸ General and the intro's
/// setup step, which asks for the shortcut alongside the permissions.
struct HotkeyRecorder: View {
    enum Style {
        /// A standard button in a Settings form, with a ✕ to reset.
        case settings
        /// One of the intro card's ink capsules, on the setup step.
        case intro
    }

    var style: Style = .settings

    @Bindable var coordinator: AppCoordinator
    @Binding var hotkey: Hotkey?
    /// The other shortcut, so the two are never recorded into a pair that
    /// cannot both fire.
    var other: Hotkey?
    /// What the ✕ puts back. Nil removes the shortcut outright; the primary
    /// passes the default, because there has to be some way in.
    var fallback: Hotkey?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflict: String?
    /// What has been pressed so far in this recording, shown in the button
    /// as it builds up.
    @State private var pending: Hotkey?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                switch style {
                case .settings:
                    Button(action: toggle) {
                        Text(label).frame(minWidth: 120)
                    }
                case .intro:
                    // Styled by the row it sits in.
                    Button(label, action: toggle)
                }
                if style == .settings, hotkey != nil, hotkey != fallback, !isRecording {
                    Button {
                        commit(fallback)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(fallback.map { "Reset to \($0.displayString)" }
                          ?? "Remove this shortcut")
                    .accessibilityLabel(fallback == nil ? "Remove shortcut"
                                                        : "Reset shortcut to default")
                }
            }
            if let conflict {
                Text(conflict)
                    .font(style == .settings ? .callout : .system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording {
            guard let pending else { return "Press a shortcut…" }
            return pending.displayString + "…"
        }
        return hotkey?.displayString ?? "None"
    }

    private func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        conflict = nil
        pending = nil
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch event.type {
            case .keyDown:
                guard event.keyCode != UInt16(kVK_Escape) else {
                    stopRecording()
                    return nil
                }
                guard !event.isARepeat else { return nil }
                // The modifiers are whatever was held with the first key;
                // later keys join it rather than restating it.
                var chord = pending.flatMap { $0.isModifierOnly ? nil : $0 }
                    ?? Hotkey(keyCodes: [], modifierFlags: flags.rawValue)
                if !chord.keyCodes.contains(event.keyCode) {
                    chord.keyCodes.append(event.keyCode)
                }
                pending = chord
                if chord.keyCodes.count == Hotkey.maxKeys { record(chord) }

            case .keyUp:
                // The first key to come back up ends the chord. A key that
                // was never part of it — Return finishing the click that
                // started recording, say — is not a release.
                if let pending, pending.keyCodes.contains(event.keyCode) {
                    record(pending)
                }

            default:
                // Modifiers alone: gathered while held, committed when the
                // last one is let go, so a stray Shift on the way to a key
                // is not it and neither is the ⌃ under ⌃A.
                guard pending?.isModifierOnly ?? true else { return nil }
                if flags.isEmpty {
                    if let pending { record(pending) }
                } else {
                    pending = Hotkey(
                        keyCodes: [],
                        modifierFlags: flags.union(pending?.modifiers ?? []).rawValue)
                }
            }
            return nil
        }
    }

    private func record(_ candidate: Hotkey) {
        if let other, let reason = Hotkey.conflict(between: candidate, and: other) {
            conflict = reason
            stopRecording()
            return
        }
        commit(candidate)
    }

    private func commit(_ hotkey: Hotkey?) {
        conflict = nil
        self.hotkey = hotkey
        coordinator.applySettings()
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
