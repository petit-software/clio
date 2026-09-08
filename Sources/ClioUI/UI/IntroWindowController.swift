import AppKit
import SwiftUI

/// The intro card as a window of its own: the welcome, then setup.
///
/// A titled window cannot have 32pt corners — AppKit owns its shape — so this
/// is a borderless, transparent window and the view draws the rounded surface.
/// The shadow is left on: it is computed from the content's alpha, so it
/// follows the card's corners rather than the window's rectangle. (The overlay
/// panel turns it off because its content resizes; this one never does.)
///
/// An `NSWindowController`-shaped object rather than a SwiftUI `Window` scene
/// because it has to be openable from the app delegate on first launch, where
/// `openWindow` is unreachable.
@MainActor
public final class IntroWindowController {
    public init() {}

    private var window: NSWindow?

    /// Shows the card, centred, at `step`. Done, Skip and Esc all close it;
    /// `onClose` runs after any of them.
    public func show(coordinator: AppCoordinator,
                     startingAt step: IntroStep = .welcome,
                     onClose: @escaping () -> Void = {}) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = IntroWindow(
            contentRect: NSRect(origin: .zero, size: IntroView.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Clio"
        let close = { [weak self] in
            self?.close()
            onClose()
        }
        window.onCancel = close
        window.contentView = NSHostingView(
            rootView: IntroView(coordinator: coordinator, startingAt: step, dismiss: close))
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.close()
        window = nil
    }
}

/// A borderless window refuses key status by default, which would leave the
/// buttons deaf to Return and Esc. This one accepts it, and turns Esc into a
/// close since there is no close button to press.
private final class IntroWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
