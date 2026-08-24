import AppKit
import Observation
import SwiftUI
import ClioCore

/// What the overlay draws. Deliberately smaller than the coordinator: the
/// panel gets state and a level, nothing else. That also keeps the ownership
/// one-directional (coordinator → controller → panel) with no cycle.
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    var level: Float = 0
}

/// The non-activating panel that shows listening / transcribing / done.
///
/// `.nonactivatingPanel` is mandatory (§5.7). If this window takes focus, the
/// frontmost app changes and the paste lands in the wrong place — the single
/// most-reported bug class in the app this one is modelled on.
@MainActor
final class OverlayController {
    let model = OverlayModel()

    private var panel: NSPanel?
    private static let size = NSSize(width: 260, height: 76)

    init() {}

    func show(position: OverlayPosition) {
        guard position != .none else { return hide() }

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrameOrigin(origin(for: position, size: panel.frame.size))
        // orderFrontRegardless, never makeKeyAndOrderFront: taking key status
        // is exactly what we must not do.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        // Without this the panel can still steal first-responder on show.
        panel.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        return panel
    }

    private func origin(for position: OverlayPosition, size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }

        switch position {
        case .none:
            return .zero
        case .topCenter:
            return NSPoint(x: frame.midX - size.width / 2,
                           y: frame.maxY - size.height - 24)
        case .bottomCenter:
            return NSPoint(x: frame.midX - size.width / 2,
                           y: frame.minY + 96)
        case .nearCursor:
            let mouse = NSEvent.mouseLocation
            // Clamped, or the pill hangs off the edge when typing near a corner.
            let x = min(max(mouse.x - size.width / 2, frame.minX + 8),
                        frame.maxX - size.width - 8)
            let y = min(max(mouse.y - size.height - 24, frame.minY + 8),
                        frame.maxY - size.height - 8)
            return NSPoint(x: x, y: y)
        }
    }
}
