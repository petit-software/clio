import AppKit
import SwiftUI

/// The window's scroll bars — the sidebar's and every page's: a 7-point
/// line, faint, no track, shown while the pointer is over what scrolls.
///
/// `scrollIndicators(.hidden)` does nothing to a `List` on macOS — the
/// table's scroll view keeps its scroller — so the scroller is replaced.
/// The system one, drawn over rows fading under the foot's blur and the
/// search field, read as a third control.
final class ThinScroller: NSScroller {
    static let knobWidth: CGFloat = 7

    /// Faded in and out by `ThinScrollers`, not by AppKit: an overlay
    /// scroller fades by drawing its knob at a falling alpha, which a custom
    /// `drawKnob` never sees, so once flashed it stayed. Starts unseen.
    func setShown(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.15 : 0.4
            animator().alphaValue = shown ? 1 : 0
        }
    }

    /// Without this a subclass forces the legacy, always-visible style.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 11 }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knob = rect(for: .knob)
        let inset = (knob.width - Self.knobWidth) / 2
        knob = knob.insetBy(dx: max(0, inset), dy: 0)
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }
}

/// Put in a `List`'s or a `ScrollView`'s background: finds the scroll view
/// beside it, gives it a `ThinScroller`, and shows the bar while the pointer
/// is over the list or page — tracked on this view, which is their size,
/// not on the scroll view: a page's runs under the sidebar on macOS 26 and
/// spans the window.
struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> Installer { Installer() }
    func updateNSView(_ view: Installer, context: Context) { view.install() }

    final class Installer: NSView {
        private weak var tracked: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The scroll view is in place a turn of the run loop after we are.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        func install() {
            guard let scrollView = nearestScrollView() else { return }
            if !(scrollView.verticalScroller is ThinScroller) {
                let scroller = ThinScroller()
                scroller.alphaValue = 0
                scrollView.verticalScroller = scroller
            }
            if tracked !== scrollView {
                tracked = scrollView
                // Tracked on this view, not the scroll view: a page's scroll
                // view runs under the sidebar on macOS 26 and spans the window,
                // while this view is the size of the list or page it backs.
                if trackingAreas.isEmpty {
                    addTrackingArea(NSTrackingArea(
                        rect: .zero,
                        options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                        owner: self, userInfo: nil))
                }
            }
            #if DEBUG
            // CLIO_SCROLLER_SHOW=1: the bars on screen, every scroll view in
            // the window scrolled a little — the sidebar for its bar, the
            // page for its top edge — without touching anything.
            if ProcessInfo.processInfo.environment["CLIO_SCROLLER_SHOW"] != nil {
                scrollView.verticalScroller?.alphaValue = 1
                if scrollView.contentView.bounds.origin.y < 1 {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 160))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            #endif
        }

        override func mouseEntered(with event: NSEvent) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIO_SCROLLER_LOG"] != nil {
                FileHandle.standardError.write(Data("[scroller] entered \(convert(bounds, to: nil)) pointer \(event.locationInWindow)\n".utf8))
            }
            #endif
            (tracked?.verticalScroller as? ThinScroller)?.setShown(true)
        }

        override func mouseExited(with event: NSEvent) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIO_SCROLLER_LOG"] != nil {
                FileHandle.standardError.write(Data("[scroller] exited\n".utf8))
            }
            #endif
            (tracked?.verticalScroller as? ThinScroller)?.setShown(false)
        }

        /// Up from here, the first ancestor with a scroll view in it: the
        /// list or page this view is the background of, before the window.
        private func nearestScrollView() -> NSScrollView? {
            var view = superview
            while let current = view {
                if let found = Self.scrollView(in: current) { return found }
                view = current.superview
            }
            return nil
        }

        private static func scrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = scrollView(in: subview) { return found }
            }
            return nil
        }

        #if DEBUG
        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            for subview in view.subviews { found += scrollViews(in: subview) }
            return found
        }
        #endif
    }
}

extension View {
    /// This list's or page's scroll bar, as `ThinScroller` draws it.
    func thinScrollers() -> some View { background(ThinScrollers()) }
}

/// A page's margins grow with the window: past `wideWidth`, the room under
/// the toolbar and either side of the text is four times a narrow page's.
/// Added around the page's content, inside its scroll view, on top of the
/// panes' own paddings — 12 under the toolbar and 28 to the text — so a
/// narrow page is exactly as it was.
struct PageMargins: ViewModifier {
    static let wideWidth: CGFloat = 520
    /// Three more of each: 12 → 48 under the toolbar, 28 → 112 at the sides.
    static let extraTop: CGFloat = 36
    static let extraHorizontal: CGFloat = 84

    @State private var isWide = false

    func body(content: Content) -> some View {
        content
            .padding(.top, isWide ? Self.extraTop : 0)
            .padding(.horizontal, isWide ? Self.extraHorizontal : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { wide in
                isWide = wide
            }
    }
}

extension View {
    func pageMargins() -> some View { modifier(PageMargins()) }
}
