import AppKit
import SwiftUI
import ClioCore

/// The system menu: what state we're in, the shortcut, and the few actions
/// worth having without opening Settings.
///
/// An NSStatusItem and an NSMenu built by hand, where it used to be a
/// MenuBarExtra. The one thing SwiftUI could not do is the first row: a
/// switch beside the name, to turn the shortcut listener off and on. A
/// Toggle inside a menu is a checkmark whatever style it is given, and only
/// an NSMenuItem with a view of its own can hold a switch. Everything else
/// is the list of items it always was, and the microphone submenu gets real
/// checkmarks out of it.
///
/// The menu is rebuilt each time it opens, which is what the SwiftUI body
/// did on every appearance. The icon is on screen all the time, so it
/// follows the coordinator through observation instead.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let openSetup: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    public init(coordinator: AppCoordinator, openSetup: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openSetup = openSetup
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        // Status bar menus follow the system appearance, not the app's.
        // This passes an app-level override (the CLIO_OVERLAY_DARK tools)
        // through, in the vibrant form a menu would have taken from the
        // system, and does nothing when there is no override.
        if NSApp.appearance?.name == .darkAqua {
            menu.appearance = NSAppearance(named: .vibrantDark)
        }
        statusItem.menu = menu
        observeIcon()
    }

    /// Whether the menu is on screen.
    public private(set) var isOpen = false

    public func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    public func menuDidClose(_ menu: NSMenu) { isOpen = false }

    /// Opens the menu, as a click on the icon would. A no-op while it is
    /// already open, so a caller can retry until it takes: a window coming
    /// up at the same moment can dismiss it.
    public func open() {
        guard !isOpen else { return }
        statusItem.button?.performClick(nil)
    }

    // MARK: Icon

    private func observeIcon() {
        withObservationTracking {
            statusItem.button?.image = icon
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeIcon() }
        }
    }

    /// The menu bar icon. It has to read at a glance whether we're recording.
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
            // than a "ready" icon that is lying — and when we have been told
            // not to listen, which from the outside is the same thing.
            return coordinator.permissions.allGranted && coordinator.isListening
                ? WaveformIcon.resting
                : WaveformIcon.muted
        }
    }

    // MARK: Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(headerItem())

        if !coordinator.permissions.allGranted || coordinator.activeModel == nil {
            menu.addItem(.separator())
            menu.addItem(item("Finish Setup…", action: openSetup))
        }

        menu.addItem(.separator())

        let recording = coordinator.state == .recording
        let dictation = item(recording ? "Stop Dictation" : "Start Dictation") { [coordinator] in
            if coordinator.state == .recording {
                coordinator.finishRecording()
            } else {
                coordinator.beginRecording()
            }
        }
        dictation.isEnabled = !(coordinator.state.isBusy && !recording)
        menu.addItem(dictation)

        let copy = item("Copy Last Transcript") { [coordinator] in coordinator.copyLastTranscript() }
        copy.isEnabled = coordinator.lastTranscript != nil
        menu.addItem(copy)

        if !coordinator.history.entries.isEmpty {
            let recent = NSMenu(title: "Recent")
            recent.autoenablesItems = false
            // Picking one copies it rather than pasting: the menu has
            // already taken focus, so the app the text belongs in is no
            // longer frontmost.
            for entry in coordinator.history.entries {
                recent.addItem(item(entry.menuLabel) { [coordinator] in coordinator.copy(entry) })
            }
            recent.addItem(.separator())
            recent.addItem(item("Clear History") { [coordinator] in coordinator.history.clear() })
            menu.addItem(Self.submenu("Recent", recent))
        }

        menu.addItem(.separator())
        menu.addItem(microphoneItem())
        menu.addItem(.separator())

        menu.addItem(item("Settings…", key: ",") { Self.openSettings() })

        if let updates = coordinator.updates {
            let check = item("Check for Updates…") { updates.checkForUpdates() }
            check.isEnabled = updates.canCheck
            menu.addItem(check)
        }

        menu.addItem(item("Quit Clio", key: "q") { NSApp.terminate(nil) })

        menu.addItem(.separator())
        // Readable, not pressable.
        menu.addItem(Self.disabled(Self.versionLine))
    }

    /// The first row: the name, the shortcut beside it in grey the way a
    /// menu shows a key equivalent — which it cannot literally be, since fn
    /// alone or a three-key chord has no key-equivalent form — and the
    /// switch. What state we are in is not repeated here: the mark in the
    /// menu bar and the pill already say, and the switch says whether the
    /// shortcut is listened for.
    private func headerItem() -> NSMenuItem {
        let hosting = NSHostingView(rootView: ListeningRow(coordinator: coordinator))
        hosting.frame.size = hosting.fittingSize
        // Stretched to the menu's width, which the other items decide.
        hosting.autoresizingMask = [.width]
        let item = NSMenuItem()
        item.view = hosting
        return item
    }

    /// The microphone picker.
    ///
    /// The shape every other macOS app uses for this: a submenu, a checkmark
    /// against the current choice, "System Default" first and named so the
    /// user can see what it currently means.
    private func microphoneItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Microphone")
        submenu.autoenablesItems = false

        let systemDefault = item(defaultTitle) { [coordinator] in coordinator.selectInputDevice(uid: nil) }
        systemDefault.state = coordinator.selectedInputUID == nil ? .on : .off
        submenu.addItem(systemDefault)

        if !coordinator.audioDevices.inputs.isEmpty {
            submenu.addItem(.separator())
        }

        for device in coordinator.audioDevices.inputs {
            let choice = item(name(for: device)) { [coordinator] in
                coordinator.selectInputDevice(uid: device.id)
            }
            choice.state = coordinator.selectedInputUID == device.id ? .on : .off
            submenu.addItem(choice)
        }

        // A microphone that was chosen and then unplugged stays visible,
        // ticked, and obviously unavailable. Dropping it silently would
        // leave the user believing they are recording from it.
        if coordinator.selectedInputIsMissing, let missing = coordinator.selectedInputUID {
            submenu.addItem(.separator())
            let gone = Self.disabled("\(Self.shortName(missing)) (not connected)")
            gone.state = .on
            gone.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                 accessibilityDescription: "Not connected")
            submenu.addItem(gone)
        }

        let title = coordinator.selectedInputIsMissing ? "Microphone ⚠" : "Microphone"
        return Self.submenu(title, submenu)
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

    /// A UID we can no longer look up — show the tail, which is usually the
    /// readable part, rather than the whole CoreAudio string.
    private static func shortName(_ uid: String) -> String {
        uid.split(separator: ":").last.map(String.init) ?? uid
    }

    /// "Clio 0.8 (412)". A `swift run` binary has no bundle to ask, so it
    /// says so rather than inventing a number.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            return "Clio (unbundled build)"
        }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Clio \(short) (\($0))" } ?? "Clio \(short)"
    }

    /// Through the app menu's own Settings… item, which SwiftUI wires to the
    /// Settings scene. A bare showSettingsWindow: sent to a nil target goes
    /// unanswered from outside a SwiftUI view.
    public static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let item = NSApp.mainMenu?.items.first?.submenu?.items
            .first { $0.keyEquivalent == "," }
        if let item, let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    // MARK: Items

    /// An item that runs a closure. NSMenuItem wants a target and selector;
    /// the closure rides on the item and the one selector dispatches to it.
    private final class ActionItem: NSMenuItem {
        var handler: () -> Void = {}
    }

    private func item(_ title: String, key: String = "",
                      action handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title: title, action: #selector(runItem(_:)), keyEquivalent: key)
        item.target = self
        item.handler = handler
        return item
    }

    @objc private func runItem(_ sender: ActionItem) {
        sender.handler()
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// The first row of the menu: name, shortcut, switch.
private struct ListeningRow: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 0) {
            Text("Clio")
            Text("   \(coordinator.settingsStore.settings.hotkeyDisplayString)")
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Toggle("Listen for the shortcut", isOn: Binding(
                get: { coordinator.isListening },
                set: { coordinator.isListening = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        // Text at the same x as the items below it, and the switch at the
        // same x as their key equivalents end.
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 3)
    }
}
