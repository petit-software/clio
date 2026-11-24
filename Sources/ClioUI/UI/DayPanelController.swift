import AppKit
import Observation
import SwiftUI
import ClioCore

/// What the day panel shows, and how far along its countdown is.
@MainActor
@Observable
final class DayPanelModel {
    var day = Date()
    /// How far the panel's clock is from the real one: zero, unless the
    /// Day View tab's Developer section has set the time.
    var clockOffset: TimeInterval = 0
    var events: [DayEvent] = []
    var position: DayPanelPosition = .center
    var countdownStyle: DayCountdownStyle = .ring
    var layout: DayLayout = .list
    /// Drives the entrance and exit; the window itself stays opaque to them.
    var isShown = false

    /// The full countdown, or zero when the panel stays until closed.
    var total: TimeInterval = 0
    /// When the panel goes away, while counting down.
    var deadline: Date?
    /// What was left when the pointer came over the panel.
    var pausedRemaining: TimeInterval?

    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onHover: (Bool) -> Void = { _ in }

    var staysUntilClosed: Bool { total <= 0 }

    /// From 1 at the start to 0 when the panel goes.
    func fractionRemaining(at now: Date) -> Double {
        guard total > 0 else { return 1 }
        let remaining = pausedRemaining ?? deadline.map { $0.timeIntervalSince(now) } ?? 0
        return min(max(remaining / total, 0), 1)
    }
}

/// The day panel: a small floating card, centred or in a corner, that
/// animates in, counts down and animates out.
@MainActor
final class DayPanelController {
    private let model = DayPanelModel()
    private var panel: DayPanel?
    private var hosting: NSHostingView<DayPanelView>?
    private var dismissTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// The screen area the panel was last placed in.
    private var visibleFrame: CGRect?
    private var resizeObserver: NSObjectProtocol?

    init() {
        model.onClose = { [weak self] in self?.dismiss() }
        model.onHover = { [weak self] inside in self?.hover(inside) }
    }

    /// Up, from the moment it is asked for: the entrance itself starts a
    /// runloop later.
    private(set) var isVisible = false
    /// Kept up by something else — a meeting card over it — whatever its
    /// own countdown or the pointer says.
    private var isHeld = false

    /// Where the card itself is on screen while it is up, without its
    /// shadow's room — for a meeting card that goes over the middle of it.
    var cardFrame: CGRect? {
        guard isVisible, let panel else { return nil }
        return panel.frame.insetBy(dx: DayPanelView.shadowMargin, dy: DayPanelView.shadowMargin)
    }

    func show(day: Date, events: [DayEvent], options: DayPanelOptions) {
        hideTask?.cancel()
        apply(day: day, events: events, options: options)
        // Held, it does not count: whatever holds it says when it goes.
        let seconds = isHeld ? 0 : options.seconds
        model.total = seconds
        isVisible = true

        let panel = panel ?? makePanel()
        place(panel)

        if !model.isShown {
            panel.orderFrontRegardless()
            // A runloop later, so the first frame is drawn in the hidden
            // pose and there is something to animate from.
            DispatchQueue.main.async { [weak self, model] in
                // Put away again before it ever arrived.
                guard self?.isVisible == true else { return }
                withAnimation(DayPanelPlacement.entrance) {
                    model.isShown = true
                }
            }
        }

        if seconds > 0 {
            schedule(after: seconds)
        } else {
            dismissTask?.cancel()
            model.deadline = nil
            model.pausedRemaining = nil
        }
    }

    /// New events or settings while the panel is up. The countdown carries
    /// on as it was.
    func update(day: Date, events: [DayEvent], options: DayPanelOptions) {
        apply(day: day, events: events, options: options)
        if let panel { place(panel) }
    }

    private func apply(day: Date, events: [DayEvent], options: DayPanelOptions) {
        model.day = day
        model.clockOffset = day.timeIntervalSinceNow
        model.events = events
        model.position = options.position
        model.countdownStyle = options.countdownStyle
        model.layout = options.layout
    }

    func dismiss() {
        dismissTask?.cancel()
        isHeld = false
        guard isVisible else { return }
        isVisible = false
        withAnimation(DayPanelPlacement.exit) {
            model.isShown = false
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: DayPanelPlacement.exitTime)
            guard let self, !Task.isCancelled, !isVisible else { return }
            panel?.orderOut(nil)
        }
    }

    // MARK: Countdown

    private func schedule(after seconds: TimeInterval) {
        dismissTask?.cancel()
        model.pausedRemaining = nil
        model.deadline = Date().addingTimeInterval(seconds)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// The countdown holds while the pointer is over the panel — whoever is
    /// reading it should not have it pulled away — and resumes from where it
    /// was when the pointer leaves.
    private func hover(_ inside: Bool) {
        guard !isHeld else { return }
        if inside { pause() } else { resume() }
    }

    /// Keeps the panel up until `release`, its countdown stopped where it
    /// was: a meeting card is over it, and the two go together.
    func hold() {
        isHeld = true
        pause()
    }

    /// Lets the countdown carry on from where `hold` stopped it.
    func release() {
        guard isHeld else { return }
        isHeld = false
        resume()
    }

    private func pause() {
        guard !model.staysUntilClosed, isVisible, let deadline = model.deadline else { return }
        dismissTask?.cancel()
        model.pausedRemaining = max(deadline.timeIntervalSinceNow, 0)
        model.deadline = nil
    }

    private func resume() {
        guard !model.staysUntilClosed, isVisible, let remaining = model.pausedRemaining else { return }
        // At least a moment, so leaving right at the end does not snap
        // the panel away under the pointer.
        schedule(after: max(remaining, 1))
    }

    // MARK: Window

    private func makePanel() -> DayPanel {
        let panel = DayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The view draws its own shadow: the window's is computed from the
        // content's alpha once, and the card scales as it animates.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.dismiss() }

        let hosting = NSHostingView(rootView: DayPanelView(model: model))
        panel.contentView = hosting

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchor() }
        }

        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Sized to the content and put where the settings say, on the screen
    /// the pointer is on — the one the user is looking at.
    private func place(_ panel: NSPanel) {
        guard let hosting else { return }
        guard let visible = DayPanelPlacement.visibleFrame() else { return }
        visibleFrame = visible

        let size = hosting.fittingSize
        panel.setFrame(NSRect(origin: origin(for: size, in: visible), size: size).integral,
                       display: true)
    }

    /// The hosting view resizes the window by itself once SwiftUI has laid
    /// out a change — after `place` measured it — and AppKit grows a window
    /// downwards from its top-left. In a bottom corner that runs off the
    /// screen, so the panel is put back against its corner.
    private func reanchor() {
        guard let panel, let visibleFrame else { return }
        let frame = panel.frame
        let origin = NSRect(origin: origin(for: frame.size, in: visibleFrame),
                            size: frame.size).integral.origin
        if origin != frame.origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func origin(for size: CGSize, in visible: CGRect) -> CGPoint {
        DayPanelPlacement.origin(for: size, in: visible, position: model.position,
                                 shadowMargin: DayPanelView.shadowMargin)
    }
}

/// Where a card goes and how it arrives: the day view's rules, kept in one
/// place because the meeting cards follow them too (`MeetingOfferController`).
@MainActor
enum DayPanelPlacement {
    /// How far a card's edge sits from the screen's, in a corner.
    static let edgeInset: CGFloat = 14
    static let entrance = Animation.spring(response: 0.45, dampingFraction: 0.8)
    static let exit = Animation.easeIn(duration: 0.2)
    /// How long the exit is given before the window is taken away.
    static let exitTime: Duration = .milliseconds(260)
    /// How small a card starts, and ends.
    static let hiddenScale: CGFloat = 0.92

    /// The usable area of the screen the pointer is on — the one the user
    /// is looking at.
    static func visibleFrame() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame
    }

    /// The origin of a window of `size` whose card sits at `position`. The
    /// window carries `shadowMargin` of clear room round the card; it is
    /// the card's own edge that sits `edgeInset` from the screen's.
    static func origin(for size: CGSize, in visible: CGRect, position: DayPanelPosition,
                       shadowMargin: CGFloat) -> CGPoint {
        let inset = edgeInset - shadowMargin
        switch position {
        case .center:
            return CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case .topLeft:
            return CGPoint(x: visible.minX + inset, y: visible.maxY - size.height - inset)
        case .topRight:
            return CGPoint(x: visible.maxX - size.width - inset, y: visible.maxY - size.height - inset)
        case .bottomLeft:
            return CGPoint(x: visible.minX + inset, y: visible.minY + inset)
        case .bottomRight:
            return CGPoint(x: visible.maxX - size.width - inset, y: visible.minY + inset)
        }
    }

    /// A card grows out of the corner it sits in, or out of its middle
    /// when centred.
    static func anchor(for position: DayPanelPosition) -> UnitPoint {
        switch position {
        case .center: .center
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    /// A short drift in from the nearest screen edge.
    static func entryOffset(for position: DayPanelPosition) -> CGFloat {
        switch position {
        case .center: 8
        case .topLeft, .topRight: -12
        case .bottomLeft, .bottomRight: 12
        }
    }
}

/// A panel that can take key status when clicked, so Esc closes it, but
/// never takes it by itself: it appears over whatever the user is typing in
/// — the rule the dictation pill keeps, for the same reason.
private final class DayPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Where it is put is where it goes. AppKit keeps a window's top out
    /// from under the menu bar, and counts the clear room for the shadow as
    /// window: in a top corner the card sat fifty points lower than asked.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
