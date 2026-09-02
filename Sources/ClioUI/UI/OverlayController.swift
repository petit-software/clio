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

    /// Mirrored from settings for the same reason as `surface`. The view
    /// derives every dimension from one height, so this is the one number
    /// that grows the whole pill.
    public var size: PillSize = .regular

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

    /// Showing where the pill will sit, rather than a real dictation.
    ///
    /// Not a `DictationState` case: previewing must not touch the state
    /// machine, or choosing a position while a recording is running would
    /// interrupt it.
    public var isPreview = false

    /// Whether the pill is meant to be seen. Flipped by the controller around
    /// ordering the panel in and out, so the view can animate the pill in and
    /// out itself: the panel appears with the pill already collapsed, grows
    /// it, and is only ordered out once it has faded.
    public var isShown = false

    /// True once the entrance has finished. Until then the pill is centred
    /// in its window so it can open from the middle; after, it is pinned to
    /// its anchored edge so state changes hold it still. Reset off screen.
    public var isSettled = false

    /// Where the pill is anchored, so the view knows which edge to hold still
    /// while its width animates.
    public var position: OverlayPosition = .bottomCenter

    /// Only while recording — a finished pill must not glow orange.
    public var isNearLimit: Bool { state == .recording && progress.isNearLimit }

    /// The design shows the ✕ while recording as well as transcribing, so
    /// both are clickable. Injecting counts too: it is drawn exactly like
    /// transcribing, and a ✕ that vanished for the 150 ms the paste takes
    /// read as a flicker between "Transcribing" and "Copied".
    public var isCancellableByClick: Bool {
        state == .recording || state == .transcribing || state == .injecting
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
    ///
    /// Measured on a second hosting view that is never on screen, bound to
    /// the same model. Measuring the visible one forces it through a layout
    /// pass at the new state's final values, and that pass discards the
    /// layout animation in flight: the capsule snapped to its new width while
    /// only its label crossfaded. This one can be forced as often as needed.
    private lazy var measuringView =
        NSHostingView(rootView: OverlayView(model: model, isMeasuring: true))

    private var contentSize: NSSize {
        measuringView.layoutSubtreeIfNeeded()
        let fitting = measuringView.fittingSize
        let minimumWidth = 120 * CGFloat(model.size.scale)
        return NSSize(width: max(fitting.width, minimumWidth), height: fitting.height)
    }

    /// Called when the user clicks the pill to abandon a transcription.
    var onCancel: (() -> Void)?

    /// Where the panel currently sits, for tooling that needs to capture it.
    public var panelFrame: NSRect? { panel?.frame }

    private var previewTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    /// How long the pill takes to close, before the panel is ordered out.
    /// Matches OverlayView.exit.
    static let hideDuration: Duration = .milliseconds(200)
    /// How long the entrance takes, after which the pill is pinned to its
    /// anchored edge. Matches OverlayView.entrance and the last Arrival beat.
    static let entranceDuration: Duration = .milliseconds(480)
    /// How long a state change takes to settle, after which the panel can be
    /// shrunk to fit without the pill visibly moving. Matches the state
    /// animation in OverlayView, with a little slack.
    static let settleDuration: Duration = .milliseconds(340)

    /// Put the pill on screen at `position` for a moment, labelled, so the
    /// choice in Settings can be seen rather than imagined.
    public func showPreview(at position: OverlayPosition,
                            surface: PillSurface,
                            size: PillSize = .regular,
                            seconds: Double = 2) {
        // Hidden has nothing to show, and a preview appearing anyway would
        // contradict the setting being chosen.
        guard position != OverlayPosition.none else {
            previewTask?.cancel()
            hide()
            return
        }

        previewTask?.cancel()
        model.surface = surface
        model.size = size
        model.isPreview = true
        model.state = .idle
        show(position: position)

        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.endPreview()
        }
    }

    private func endPreview() {
        guard model.isPreview else { return }
        model.isPreview = false
        hide()
    }

    /// A real session takes the pill back at once, however long the preview
    /// had left to run.
    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        model.isPreview = false
    }

    public init() {}

    /// Take the look chosen in Settings. Refits the window if the pill is on
    /// screen, since a bigger pill in a window that has not grown is clipped.
    public func apply(surface: PillSurface, size: PillSize) {
        model.surface = surface
        model.size = size
        resize()
    }

    /// Drives the elapsed readout while recording.
    public func updateProgress(elapsed: TimeInterval, limit: TimeInterval) {
        model.progress = RecordingProgress(elapsed: elapsed, limit: limit)
    }

    /// Mirrors the machine's state into the pill, and decides whether the panel
    /// takes the pointer at all.
    public func update(state: DictationState, note: String? = nil) {
        // Idle is never drawn. The pill fades out saying whatever it said
        // last and is reset once it is off screen — see hide(). Drawing idle
        // at once shrank the capsule to nothing while it faded, and clipped
        // the last word on the way.
        if state == .idle {
            if panel?.isVisible == true {
                hide()
            } else {
                model.state = .idle
                model.note = nil
            }
            return
        }
        cancelPreview()
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
        // Read once per session. Re-reading on every resize made the pill
        // chase the pointer from state to state.
        if position == .nearCursor, !(panel?.isVisible ?? false) {
            cursorAnchor = NSEvent.mouseLocation
        }
        // A hide that was still fading is abandoned; the pill comes back from
        // wherever it had got to.
        hideTask?.cancel()
        hideTask = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        model.position = position
        panel.ignoresMouseEvents = !model.isCancellableByClick
        panel.setContentSize(contentSize)
        panel.setFrameOrigin(origin(for: position, size: panel.frame.size))

        if panel.isVisible {
            model.isShown = true
            return
        }
        // Rendered collapsed FIRST, then shown, so the first frame on screen
        // is the start of the entrance rather than the end of it. Without the
        // forced layout SwiftUI coalesces the two writes and nothing animates.
        // Forcing here is fine: the panel is not on screen yet, and this is
        // the one state that must NOT animate.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { model.isShown = false }
        hostingView?.layoutSubtreeIfNeeded()
        // orderFrontRegardless, never makeKeyAndOrderFront: taking key status
        // is exactly what we must not do.
        panel.orderFrontRegardless()
        model.isShown = true
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.entranceDuration)
            guard !Task.isCancelled else { return }
            self?.model.isSettled = true
        }
    }

    func hide() {
        guard let panel, panel.isVisible, hideTask == nil else { return }
        shrinkTask?.cancel()
        shrinkTask = nil
        settleTask?.cancel()
        settleTask = nil
        model.isShown = false
        model.isHovering = false
        // Ordered out only once the pill has faded. If show() lands in the
        // meantime it cancels this and the panel simply stays.
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDuration)
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            self.panel?.orderOut(nil)
            // Reset off screen, where nothing animates.
            self.model.state = .idle
            self.model.note = nil
            self.model.isSettled = false
        }
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
    ///
    /// The window is never animated. The pill animates its own width inside
    /// it, held to the anchored edge, so all the window has to do is be big
    /// enough: it grows at once, before the pill does, and shrinks only after
    /// the pill has finished — a window that is briefly too large is
    /// transparent, but one that is briefly too small clips the pill.
    private func resize() {
        shrinkTask?.cancel()
        shrinkTask = nil
        guard let panel, panel.isVisible else { return }
        let size = contentSize
        guard size != panel.frame.size else { return }
        if size.width > panel.frame.width || size.height > panel.frame.height {
            setFrame(size)
        } else {
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: Self.settleDuration)
                guard !Task.isCancelled, let self else { return }
                self.shrinkTask = nil
                // Measured again: the state may have moved on since.
                self.setFrame(self.contentSize)
            }
        }
    }

    private func setFrame(_ size: NSSize) {
        guard let panel, size != panel.frame.size else { return }
        panel.setFrame(NSRect(origin: origin(for: currentPosition, size: size),
                              size: size),
                       display: true)
    }

    private var currentPosition: OverlayPosition = .bottomCenter
    /// Where the pointer was when a near-cursor session began.
    private var cursorAnchor: NSPoint = .zero

    /// How far the pill sits from the edge of the usable screen area, the same
    /// on every side and in every position.
    ///
    /// Bottom centre used to be held further out than the rest, to clear the
    /// strip that reveals a hidden Dock. At this distance it clears it anyway,
    /// and one position quietly sitting further out than its neighbours looked
    /// like a bug when they were compared.
    static let edgeGap: CGFloat = 64

    private func origin(for position: OverlayPosition, size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }

        // The gap between the PILL and the edge of the usable screen area.
        //
        // The window is bigger than the pill by shadowPadding on every side —
        // transparent room so the shadow is not clipped — so that is taken off
        // here. Before this, the constant read 24 and the pill sat 38 away,
        // and the two numbers had to be added by whoever went looking.
        //
        // Measured from the VISIBLE frame, which already excludes the menu bar
        // and the Dock; from the screen it would sit underneath both.
        let gap = Self.edgeGap - OverlayView.shadowPadding

        switch position {
        case .none:
            return .zero
        case .topLeft:
            return NSPoint(x: frame.minX + gap, y: frame.maxY - size.height - gap)
        case .topCenter:
            return NSPoint(x: frame.midX - size.width / 2,
                           y: frame.maxY - size.height - gap)
        case .topRight:
            return NSPoint(x: frame.maxX - size.width - gap,
                           y: frame.maxY - size.height - gap)
        case .bottomLeft:
            return NSPoint(x: frame.minX + gap, y: frame.minY + gap)
        case .bottomCenter:
            return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + gap)
        case .bottomRight:
            return NSPoint(x: frame.maxX - size.width - gap, y: frame.minY + gap)
        case .nearCursor:
            let mouse = cursorAnchor
            // Clamped, or the pill hangs off the edge when typing near a corner.
            let x = min(max(mouse.x - size.width / 2, frame.minX + 8),
                        frame.maxX - size.width - 8)
            let y = min(max(mouse.y - size.height - 24, frame.minY + 8),
                        frame.maxY - size.height - 8)
            return NSPoint(x: x, y: y)
        }
    }
}
