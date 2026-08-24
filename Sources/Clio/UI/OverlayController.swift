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
    /// Set by the panel's tracking area, not by SwiftUI's `.onHover`.
    var isHovering = false

    /// How long the current recording has been running, and the cap it is
    /// heading for. Shown because the recording stops at that cap whether or
    /// not the user has finished a sentence, and being cut off mid-thought
    /// with no warning is the worst version of that.
    var progress = RecordingProgress()

    /// Something worth saying after the fact — that the recording hit its
    /// limit, say — shown under the main label.
    var note: String?

    /// Only while recording — a finished pill must not glow orange.
    var isNearLimit: Bool { state == .recording && progress.isNearLimit }

    /// Transcribing can take seconds on a large model, and it is the one wait
    /// worth offering a way out of. Recording already ends by releasing the
    /// key, and injecting is over before a cursor could reach it.
    var isCancellableByClick: Bool { state == .transcribing }
}

/// Hosts the pill and handles the pointer itself.
///
/// SwiftUI's `.onHover` installs a tracking area that only fires for the key
/// window of an active application. Clio is an accessory app that is
/// deliberately never active while this panel is up, so hover has to be
/// tracked explicitly with `.activeAlways`. The click is taken here too, for
/// the same reason — and because the whole pill is a bigger, calmer target
/// than a 16pt button.
@MainActor
final class OverlayHostingView: NSHostingView<OverlayView> {
    var onCancel: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private let model: OverlayModel

    init(model: OverlayModel) {
        self.model = model
        super.init(rootView: OverlayView(model: model))
    }

    @MainActor required init(rootView: OverlayView) {
        self.model = rootView.model
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        model.isHovering = true
        if model.isCancellableByClick { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        model.isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard model.isCancellableByClick else { return }
        NSCursor.arrow.set()
        onCancel?()
    }
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
    private var hostingView: OverlayHostingView?
    private static let size = NSSize(width: 260, height: 76)

    /// Called when the user clicks the pill to abandon a transcription.
    var onCancel: (() -> Void)?

    init() {}

    /// Mirrors the machine's state into the pill, and decides whether the panel
    /// takes the pointer at all.
    /// Drives the elapsed readout while recording.
    func updateProgress(elapsed: TimeInterval, limit: TimeInterval) {
        model.progress = RecordingProgress(elapsed: elapsed, limit: limit)
    }

    func update(state: DictationState, note: String? = nil) {
        model.state = state
        model.note = note
        if state == .recording { model.progress.elapsed = 0 }
        if !model.isCancellableByClick {
            model.isHovering = false
        }
        // Click-through except while there is something to cancel. The panel
        // sits over other apps, and swallowing clicks it has no use for would
        // make it an obstacle.
        panel?.ignoresMouseEvents = !model.isCancellableByClick
    }

    func show(position: OverlayPosition) {
        guard position != .none else { return hide() }

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = !model.isCancellableByClick
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
        // Set per state by update(state:) — see there.
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        // Without this the panel can still steal first-responder on show.
        panel.becomesKeyOnlyIfNeeded = true

        let host = OverlayHostingView(model: model)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.onCancel = { [weak self] in self?.onCancel?() }
        hostingView = host
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
