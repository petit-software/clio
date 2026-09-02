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
                        openOnboarding: delegate.showOnboarding)
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

/// Owns the coordinator and the onboarding window.
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
        #else
        return false
        #endif
    }
    private let onboarding = OnboardingWindowController()
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
        #endif

        // Belt and braces: Info.plist carries LSUIElement, but a `swift run`
        // build has no bundle and would otherwise show a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        coordinator.start()

        if !coordinator.permissions.allGranted {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showOnboarding() {
        onboarding.show(coordinator: coordinator)
    }
}
