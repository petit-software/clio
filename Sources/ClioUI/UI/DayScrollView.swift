import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var isDayPanelHovered = false
}

/// A shared narrow rail with native wheel, trackpad, and thumb tracking.
struct DayScrollView<Content: View>: NSViewRepresentable {
    @Environment(\.isDayPanelHovered) private var isPanelHovered

    let initialCenter: CGFloat
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> DayScrollContainer {
        let scroll = DayScrollContainer()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller = DayScroller()
        scroll.initialCenter = initialCenter

        let document = NSHostingView(rootView: content())
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    func updateNSView(_ scroll: DayScrollContainer, context: Context) {
        scroll.verticalScroller?.alphaValue = isPanelHovered ? 1 : 0
        (scroll.documentView as? NSHostingView<Content>)?.rootView = content()
    }
}

final class DayScrollContainer: NSScrollView {
    var initialCenter: CGFloat?

    override func layout() {
        super.layout()
        guard let initialCenter, let documentView,
              contentView.bounds.height > 0,
              documentView.frame.height > contentView.bounds.height else { return }
        self.initialCenter = nil
        let offset = min(max(0, initialCenter - contentView.bounds.height / 2),
                         documentView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: offset))
        reflectScrolledClipView(contentView)
    }
}

private final class DayScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {
        guard knobProportion < 1 else { return }
        drawCapsule(in: bounds, color: .labelColor.withAlphaComponent(0.08))
        drawCapsule(in: rect(for: .knob), color: .secondaryLabelColor)
    }

    private func drawCapsule(in rect: NSRect, color: NSColor) {
        let rail = NSRect(x: bounds.midX - 2, y: rect.minY + 1,
                          width: 4, height: max(0, rect.height - 2))
        color.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).fill()
    }
}
