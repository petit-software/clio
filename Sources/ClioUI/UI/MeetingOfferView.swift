import AppKit
import SwiftUI
import ClioCore

/// "Take notes for Weekly sync?" — a small card in the top-right corner when
/// a call starts.
///
/// A non-activating panel, like the pill: it must never take focus from the
/// call the user is joining. It goes away on its own after half a minute,
/// since saying nothing is also an answer.
@MainActor
final class MeetingOfferController {
    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    static let size = CGSize(width: 340, height: 124)

    func show(title: String?, app: CallApp, accept: @escaping () -> Void) {
        dismiss()
        let view = MeetingOfferView(
            title: title, appName: app.name,
            accept: { [weak self] in
                self?.dismiss()
                accept()
            },
            decline: { [weak self] in self?.dismiss() })

        let panel = OfferPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - 16,
                                         y: frame.maxY - Self.size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Takes clicks without making Clio the active app.
private final class OfferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct MeetingOfferView: View {
    let title: String?
    let appName: String
    let accept: () -> Void
    let decline: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: IntroPalette { IntroPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.map { "Take notes for “\($0)”?" } ?? "Take notes for this call?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text("\(appName) is on a call. Both sides are transcribed on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: decline) {
                    Text("Not Now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .introGlassButton(.utility, palette: palette)

                Button(action: accept) {
                    Text("Take Notes")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.inkLabel)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .introGlassButton(.prominent, palette: palette)
            }
        }
        .padding(14)
        .frame(width: MeetingOfferController.size.width - 2,
               height: MeetingOfferController.size.height - 2)
        .background(OfferSurface(palette: palette))
        .padding(1)
    }
}

/// The intro card's glass, at the offer's smaller radius.
private struct OfferSurface: View {
    let palette: IntroPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(palette.surface.opacity(0.58))
                    .glassEffect(.regular.tint(palette.glassTint), in: shape)
            } else {
                shape.fill(palette.surface)
            }
        }
        .overlay(shape.inset(by: -1).strokeBorder(palette.outline, lineWidth: 0.5))
    }
}

#if DEBUG
#Preview("Meeting offer") {
    MeetingOfferView(title: "Weekly sync", appName: "Zoom", accept: {}, decline: {})
        .padding(30)
        .background(Color(nsColor: .underPageBackgroundColor))
}
#endif
