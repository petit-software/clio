import AppKit
import Observation
import SwiftUI
import ClioCore

/// What the overlay draws. Deliberately smaller than the coordinator: the
/// panel gets state and a level, nothing else. That also keeps the ownership
/// one-directional (coordinator → controller → panel) with no cycle.
@MainActor
@Observable
public final class OverlayModel {
    public var state: DictationState = .idle
    public var level: Float = 0
    /// Set by the panel's tracking area, not by SwiftUI's `.onHover`.
    public var isHovering = false

    /// How long the current recording has been running, and the cap it is
    /// heading for. Shown because the recording stops at that cap whether or
    /// not the user has finished a sentence, and being cut off mid-thought
    /// with no warning is the worst version of that.
    public var progress = RecordingProgress()

    /// Something worth saying after the fact — that the recording hit its
    /// limit, say — shown under the main label.
    public var note: String?

    /// Mirrored from settings so the pill can be redrawn without the view
    /// reaching for a settings store it should not know about.
    public var surface = PillSurface()

    /// False while the microphone is still starting. The pill is on screen
    /// before that, and a level meter sitting dead at zero reads as broken —
    /// so it says it is waking instead.
    public var captureIsLive = false

    /// Whether the finished transcript actually ended up on the clipboard.
    ///
    /// Pasting borrows the clipboard and puts back what was there, so most of
    /// the time it does not. Saying "Copied to clipboard" regardless would send
    /// the user to a clipboard that no longer holds their words.
    public var transcriptIsOnClipboard = false

    /// Only while recording — a finished pill must not glow orange.
    public var isNearLimit: Bool { state == .recording && progress.isNearLimit }

    /// The design shows the ✕ while recording as well as transcribing, so
    /// both are clickable. Injecting is over before a cursor could reach it.
    public var isCancellableByClick: Bool {
        state == .recording || state == .transcribing
    }
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
public final class OverlayController {
    public let model = OverlayModel()

    private var panel: NSPanel?
    private var hostingView: OverlayHostingView?

    /// The pill is as wide as its content — "Transcribing" needs more room
    /// than a level meter, and an error message more again — so the panel is
    /// measured from the view rather than fixed.
    private var contentSize: NSSize {
        guard let hostingView else {
            return NSSize(width: 200, height: OverlayView.height + OverlayView.shadowPadding * 2)
        }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        return NSSize(width: max(fitting.width, 120), height: fitting.height)
    }

    /// Called when the user clicks the pill to abandon a transcription.
    var onCancel: (() -> Void)?

    /// Where the panel currently sits, for tooling that needs to capture it.
    public var panelFrame: NSRect? { panel?.frame }

    public init() {}

    /// Mirrors the machine's state into the pill, and decides whether the panel
    /// takes the pointer at all.
    /// Drives the elapsed readout while recording.
    public func updateProgress(elapsed: TimeInterval, limit: TimeInterval) {
        model.progress = RecordingProgress(elapsed: elapsed, limit: limit)
    }

    public func update(state: DictationState, note: String? = nil) {
        model.state = state
        model.note = note
        if state == .recording { model.progress.elapsed = 0 }
        if state != .recording { model.captureIsLive = false }
        if !model.isCancellableByClick {
            model.isHovering = false
        }
        // The pill changes width with its content, so the window has to follow
        // — and stay put where it was anchored while doing it.
        resize()
        // Click-through except while there is something to cancel. The panel
        // sits over other apps, and swallowing clicks it has no use for would
        // make it an obstacle.
        panel?.ignoresMouseEvents = !model.isCancellableByClick
    }

    public func show(position: OverlayPosition) {
        // Spelled out. `position` is not an Optional today, but if it ever
        // becomes one a bare `.none` silently starts meaning nil instead.
        guard position != OverlayPosition.none else { return hide() }
        currentPosition = position

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = !model.isCancellableByClick
        panel.setContentSize(contentSize)
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
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        // Set per state by update(state:) — see there.
        panel.ignoresMouseEvents = true
        // The window draws NO shadow of its own. macOS derives one from the
        // content's alpha and caches it, and this panel both resizes per state
        // and is translucent — so the cached shape goes stale and renders as a
        // hard outline tracing a pill that is no longer there. The shadow in
        // OverlayView follows the capsule exactly and redraws with it.
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        // Without this the panel can still steal first-responder on show.
        panel.becomesKeyOnlyIfNeeded = true

        let host = OverlayHostingView(model: model)
        host.frame = NSRect(origin: .zero, size: contentSize)
        host.onCancel = { [weak self] in self?.onCancel?() }
        hostingView = host
        panel.contentView = host
        return panel
    }

    /// Re-measure and keep the pill anchored where the user put it.
    private func resize() {
        guard let panel, panel.isVisible else { return }
        let size = contentSize
        guard size != panel.frame.size else { return }
        panel.setFrame(NSRect(origin: origin(for: currentPosition, size: size),
                              size: size),
                       display: true)
    }

    private var currentPosition: OverlayPosition = .bottomCenter

    private func origin(for position: OverlayPosition, size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }

        // Inset from the visible frame, which already excludes the menu bar
        // and the Dock — a corner measured from the screen would sit under
        // them.
        let margin: CGFloat = 24

        switch position {
        case .none:
            return .zero
        case .topLeft:
            return NSPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin)
        case .topCenter:
            return NSPoint(x: frame.midX - size.width / 2,
                           y: frame.maxY - size.height - margin)
        case .topRight:
            return NSPoint(x: frame.maxX - size.width - margin,
                           y: frame.maxY - size.height - margin)
        case .bottomLeft:
            return NSPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomCenter:
            // Higher than the other two: the Dock's reveal area is here, and a
            // pill sitting in it flickers as the Dock comes and goes.
            return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 96)
        case .bottomRight:
            return NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
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
