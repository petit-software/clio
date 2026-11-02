import AppKit
import SwiftUI
import ClioCore
import ClioUI

@main
struct ClioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item is AppKit, owned by the delegate — see
        // MenuBarController for why it is not a MenuBarExtra.
        Settings {
            SettingsView(coordinator: delegate.coordinator)
                .onAppear { delegate.coordinator.permissions.refresh() }
        }
    }
}

/// Owns the coordinator, the menu bar item and the intro window.
///
/// The coordinator lives here rather than in `@State` on the App so that
/// `applicationWillTerminate` can shut it down — settings are debounced, and a
/// quit inside the debounce window would otherwise lose the last change.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // No updater in the overlay tool modes. Starting Sparkle from a bare
    // `swift run` binary puts up its first-launch permission alert, and that
    // alert is modal: it blocks the main actor, and with it every timed step
    // the sequence tool takes.
    let coordinator = AppCoordinator(updates: AppDelegate.isOverlayTool ? nil : UpdateManager())

    private static var isOverlayTool: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CLIO_OVERLAY_DUMP"] != nil || env["CLIO_OVERLAY_SHOW"] != nil
            || env["CLIO_INTRO_SHOW"] != nil || env["CLIO_SETTINGS_SHOW"] != nil
            || env["CLIO_MENU_SHOW"] != nil || env["CLIO_MEETING_SHOW"] != nil
            || env["CLIO_OFFER_SHOW"] != nil || env["CLIO_LIBRARY_SHOW"] != nil
            || env["CLIO_MARKDOWN_CHECK"] != nil
        #else
        return false
        #endif
    }
    private var isMenuTool: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CLIO_MENU_SHOW"] != nil
        #else
        false
        #endif
    }
    private let intro = IntroWindowController()
    private var menuBar: MenuBarController?
    #if DEBUG
    private var overlayPreview: OverlayController?
    #endif

    /// The tools' appearance: CLIO_OVERLAY_DARK forces dark, and
    /// CLIO_OVERLAY_LIGHT light — for a Mac that is itself set to dark.
    private static func applyToolAppearance() {
        let env = ProcessInfo.processInfo.environment
        if env["CLIO_OVERLAY_DARK"] != nil {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if env["CLIO_OVERLAY_LIGHT"] != nil {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hammer the recorder against the machine's microphones and quit. Not
        // DEBUG-only: it has to run from the signed bundle, which is the
        // only process allowed the microphone, and the bundle is a release
        // build.
        //
        // Each microphone in turn, not just the configured one: a fault that
        // belongs to one device is invisible from another, and a run against
        // the configured microphone alone was once clean on a machine where
        // three inputs out of five could not record.
        if let count = ProcessInfo.processInfo.environment["CLIO_RECORDER_STRESS"].flatMap(Int.init) {
            Task { @MainActor in
                // CLIO_RECORDER_STRESS_ALL=1 adds the microphones that
                // cannot be opened without somebody noticing: Bluetooth
                // headsets, and an iPhone. Ask whoever is wearing them first.
                let everything = ProcessInfo.processInfo
                    .environment["CLIO_RECORDER_STRESS_ALL"] != nil
                let (devices, skipped, failures, timings) =
                    await AudioRecorder.sweep(cycles: count, everything: everything)
                let swept = "\(count) cycles × \(devices.count) inputs"
                    + (skipped.isEmpty ? "" : ", NOT opened: \(skipped.joined(separator: ", "))")
                let outcome = failures.isEmpty
                    ? "[recorder stress] \(swept): no failures\n"
                    : "[recorder stress] \(swept), \(failures.count) failed:\n"
                        + failures.joined(separator: "\n") + "\n"
                let report = timings.map { "[recorder stress] \($0)\n" }.joined() + outcome
                FileHandle.standardError.write(Data(report.utf8))
                exit(failures.isEmpty ? 0 : 1)
            }
            return
        }
        // Listen to system audio through the meeting tap and quit. Not
        // DEBUG-only, for the reason the stress is not: the permission is
        // the signed bundle's.
        if let seconds = ProcessInfo.processInfo.environment["CLIO_SYSTEM_AUDIO_TEST"]
            .flatMap(Double.init) {
            let out = ProcessInfo.processInfo.environment["CLIO_SYSTEM_AUDIO_OUT"]
                .map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let flip = ProcessInfo.processInfo.environment["CLIO_SYSTEM_AUDIO_FLIP_RATE"] != nil
                let report = await SystemAudioRecorder.check(seconds: seconds, writingTo: out,
                                                             flipRate: flip)
                FileHandle.standardError.write(Data((report + "\n").utf8))
                exit(report.contains("heard sound: yes") ? 0 : 1)
            }
            return
        }
        // A real meeting, recorded and transcribed, then quit.
        if let seconds = ProcessInfo.processInfo.environment["CLIO_MEETING_TEST"]
            .flatMap(Double.init) {
            Task { @MainActor in
                let report = await coordinator.runMeetingCheck(seconds: seconds)
                FileHandle.standardError.write(Data((report + "\n").utf8))
                exit(report.contains("FAILED") ? 1 : 0)
            }
            return
        }
        #if DEBUG
        // The meeting window, filled with a meeting that never happened, in
        // the state named: recording, finishing, finished, silent.
        if let which = ProcessInfo.processInfo.environment["CLIO_MEETING_SHOW"] {
            NSApp.setActivationPolicy(.accessory)
            Self.applyToolAppearance()
            coordinator.showSimulatedMeeting(which)
            return
        }
        // Every Markdown editing rule, through a real text view; then quit.
        if ProcessInfo.processInfo.environment["CLIO_MARKDOWN_CHECK"] != nil {
            NSApp.setActivationPolicy(.accessory)
            let results = MarkdownEditorCheck.run()
            exit(results.contains { $0.hasPrefix("FAIL") } ? 1 : 0)
        }
        // The library window on sample meetings; "live" adds a recording.
        if let which = ProcessInfo.processInfo.environment["CLIO_LIBRARY_SHOW"] {
            Self.applyToolAppearance()
            coordinator.showSimulatedLibrary(which)
            return
        }
        // The card offered when a call starts, top right.
        if ProcessInfo.processInfo.environment["CLIO_OFFER_SHOW"] != nil {
            NSApp.setActivationPolicy(.accessory)
            Self.applyToolAppearance()
            if ProcessInfo.processInfo.environment["CLIO_OFFER_SHOW"] == "click" {
                coordinator.clickSimulatedOffer()
            } else {
                coordinator.showSimulatedOffer()
            }
            return
        }
        // Render the overlay states and quit, without starting the app proper.
        if let directory = ProcessInfo.processInfo.environment["CLIO_OVERLAY_DUMP"] {
            OverlayDump.write(to: URL(fileURLWithPath: directory))
            NSApp.terminate(nil)
            return
        }
        // Shows the panel and stays up, so glass can be judged on screen.
        if let state = ProcessInfo.processInfo.environment["CLIO_OVERLAY_SHOW"] {
            overlayPreview = OverlayDump.show(state: state)
            return
        }
        // The intro card on screen, alone. Previews show its layout; the
        // window's own corners and shadow can only be judged here. The
        // coordinator is real but not started, so the permission rows show
        // this Mac's actual state and a download actually downloads.
        if let which = ProcessInfo.processInfo.environment["CLIO_INTRO_SHOW"] {
            NSApp.setActivationPolicy(.accessory)
            Self.applyToolAppearance()
            // `downloading` and `waiting` are the setup step mid-download,
            // on a simulated coordinator: this Mac has a model already.
            if which == "downloading" || which == "waiting" {
                intro.showSimulated(which) { NSApp.terminate(nil) }
                return
            }
            intro.show(coordinator: coordinator,
                       startingAt: which == "setup" ? .setup : .welcome) {
                NSApp.terminate(nil)
            }
            return
        }
        // The Settings window, alone. Its tab bar draws the icons at a size
        // and weight that no preview reproduces, so they are judged here.
        if ProcessInfo.processInfo.environment["CLIO_SETTINGS_SHOW"] != nil {
            NSApp.setActivationPolicy(.accessory)
            Self.applyToolAppearance()
            // Through the Settings scene: the scene is what gives the
            // TabView its icon-and-label tab bar, and a TabView hosted in a
            // plain window draws a segmented control with no icons at all.
            // A beat after launch, since the scene is not in the responder
            // chain until SwiftUI has finished setting up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MenuBarController.openSettings()
            }
            return
        }
        #endif

        // Belt and braces: Info.plist carries LSUIElement, but a `swift run`
        // build has no bundle and would otherwise show a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        coordinator.start()

        #if DEBUG
        // Before the menu exists: it reads the app's appearance once, when
        // it is built — see MenuBarController.
        if ProcessInfo.processInfo.environment["CLIO_MENU_SHOW"] != nil,
           ProcessInfo.processInfo.environment["CLIO_OVERLAY_DARK"] != nil {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #endif

        menuBar = MenuBarController(coordinator: coordinator) { [weak self] in self?.showSetup() }

        #if DEBUG
        // The status menu, opened, so it can be looked at without a mouse.
        if ProcessInfo.processInfo.environment["CLIO_MENU_SHOW"] != nil {
            // Retried for a few seconds: a window coming up at the same
            // moment can dismiss a menu that has just opened.
            func tryToOpen(attempt: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    menuBar?.open()
                    if attempt < 6, menuBar?.isOpen != true {
                        tryToOpen(attempt: attempt + 1)
                    }
                }
            }
            tryToOpen(attempt: 1)
        }
        #endif

        // Anything missing that the app cannot work without, and the intro
        // comes up. Skipping it is allowed, so this can happen more than once.
        //
        // Not in the menu tool. The card would activate the app, and the
        // menu is to be seen the way a user sees it: opened over someone
        // else's window, with Clio inactive — which is the state its
        // controls draw in.
        if !coordinator.permissions.allGranted || coordinator.activeModel == nil,
           !isMenuTool {
            intro.show(coordinator: coordinator)
        }
    }

    /// Quitting during a meeting finishes its transcript first — a few
    /// seconds, at most ten — rather than dropping the last thing said.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.isMeetingActive else { return .terminateNow }
        Task { @MainActor in
            await coordinator.finishMeetingBeforeQuitting(within: 10)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// From the menu bar's "Finish Setup…": straight to the setup step,
    /// since whoever is asking has already seen the welcome.
    func showSetup() {
        intro.show(coordinator: coordinator, startingAt: .setup)
    }
}
