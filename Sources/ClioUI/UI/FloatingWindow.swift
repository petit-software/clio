import AppKit
import SwiftUI

/// Keeps the window a SwiftUI view is hosted in above other apps' windows.
///
/// Clio is a menu bar app with no Dock icon, so its Settings window has no
/// app to come forward with: opened from the menu it appeared and was then
/// covered by whatever the user was working in. Floating keeps it on top
/// until it is closed, which for a window used to tune a shortcut while
/// looking at another app is what is wanted.
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.moveToActiveSpace)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension View {
    /// The window this view lives in stays above other apps.
    public func floatingWindow() -> some View {
        background(FloatingWindow())
    }
}
