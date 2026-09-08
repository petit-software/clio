import AppKit
import SwiftUI
import ClioCore
import ClioUI

@main
struct ClioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: delegate.coordinator,
                        openSetup: delegate.showSetup)
        } label: {
            MenuBarLabel(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: delegate.coordinator)
                .onAppear { delegate.coordinator.permissions.refresh() }
        }
    }
}

/// Owns the coordinator and the intro window.
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
            || env["CLIO_INTRO_SHOW"] != nil
        #else
        return false
        #endif
    }
    private let intro = IntroWindowController()
    #if DEBUG
    private var overlayPreview: OverlayController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
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
            if ProcessInfo.processInfo.environment["CLIO_OVERLAY_DARK"] != nil {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            intro.show(coordinator: coordinator,
                       startingAt: which == "setup" ? .setup : .welcome) {
                NSApp.terminate(nil)
            }
            return
        }
        #endif

        // Belt and braces: Info.plist carries LSUIElement, but a `swift run`
        // build has no bundle and would otherwise show a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        coordinator.start()

        // Anything missing that the app cannot work without, and the intro
        // comes up. Skipping it is allowed, so this can happen more than once.
        if !coordinator.permissions.allGranted || coordinator.activeModel == nil {
            intro.show(coordinator: coordinator)
        }
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
