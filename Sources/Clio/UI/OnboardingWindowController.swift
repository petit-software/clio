import AppKit
import SwiftUI

/// Onboarding as a plain NSWindow rather than a SwiftUI `Window` scene.
///
/// A `Window` scene can only be opened through the `openWindow` environment
/// value, which is unreachable from the app delegate — and first run is
/// exactly when this window has to appear. An NSWindowController can be opened
/// from anywhere, which is the whole reason it exists here.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(coordinator: AppCoordinator) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        window.title = "Welcome to Clio"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView(coordinator: coordinator) { [weak self] in
                self?.close()
            })

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
