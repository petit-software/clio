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

    /// The card, with the point either side of it its hairline is drawn in.
    static let cardSize = CGSize(width: 340, height: 124)
    /// Room round the card for the shadow it casts: the card draws its
    /// own, as the onboarding card does, and the panel casts none.
    static let shadowMargin: CGFloat = 36
    /// The panel: the card and its shadow's room.
    static let size = CGSize(width: cardSize.width + 2 * shadowMargin,
                             height: cardSize.height + 2 * shadowMargin)

    /// A call app has opened its microphone: take notes for it?
    func show(title: String?, app: CallApp, accept: @escaping () -> Void,
              decline: @escaping () -> Void = {}) {
        show(MeetingOffer(
            headline: title.map { "Take notes for “\($0)”?" } ?? "Take notes for this call?",
            detail: "\(app.name) is on a call. Both sides are transcribed on this Mac.",
            acceptTitle: "Take Notes", declineTitle: "Not Now"),
             accept: accept, decline: decline)
    }

    /// Shows a card. It goes after `timeout` seconds, with `onTimeout` if
    /// nothing was pressed — saying nothing is an answer too.
    func show(_ offer: MeetingOffer, timeout seconds: TimeInterval = 30,
              accept: @escaping () -> Void, decline: @escaping () -> Void = {},
              onTimeout: @escaping () -> Void = {}) {
        dismiss()
        let view = MeetingOfferView(
            offer: offer,
            accept: { [weak self] in
                self?.dismiss()
                accept()
            },
            decline: { [weak self] in
                self?.dismiss()
                decline()
            })

        let panel = OfferPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card's own shadow (`OfferSurface`), which is where the card
        // is; the window's is wherever the card was when it was taken.
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = FirstClickHostingView(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // The card where it always was — 16 in from the right, 12 down
            // from the top — with its shadow's room hanging outside that.
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - Self.cardSize.width - 16 - Self.shadowMargin,
                y: frame.maxY - Self.cardSize.height - 12 - Self.shadowMargin))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
            onTimeout()
        }
    }

    var isShowing: Bool { panel != nil }

    #if DEBUG
    /// Clicks the card the way the window server would — a mouse down and up
    /// at `point` from the panel's bottom-left — for the CLIO_OFFER_SHOW=click
    /// tool to prove the buttons hear a first click.
    func click(at point: NSPoint) {
        guard let panel else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.sendEvent(event)
            }
        }
    }
    #endif

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Non-activating: a click makes the card key for that click without
/// making Clio the active app, so the call keeps its place in front.
private final class OfferPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Clio is never the active app while the card is up, so the first click on
/// it is the one that matters — without this AppKit spends it on bringing
/// the window forward and the button never hears it.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One capsule for both of the card's buttons, in the fill it is given.
private struct OfferButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

/// What a card says: a question, a line under it, and its two answers.
struct MeetingOffer {
    var headline: String
    var detail: String
    var acceptTitle: String
    var declineTitle: String
    /// Set, the detail counts down to it: `detail` with "%d" for the
    /// seconds left.
    var deadline: Date?
}

struct MeetingOfferView: View {
    static let buttonHeight: CGFloat = 32

    let offer: MeetingOffer
    let accept: () -> Void
    let decline: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: IntroPalette { IntroPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Group {
                    if let deadline = offer.deadline {
                        // Counting down, a second at a time.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(String(format: offer.detail,
                                        max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))))
                                .monospacedDigit()
                        }
                    } else {
                        Text(offer.detail)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            // Two buttons of one size: half the card each, one height. They
            // were two styles — the system's glass, which pads its label,
            // and the card's own ink, which does not — and the one that
            // mattered came out the smaller.
            HStack(spacing: 8) {
                Button(action: decline) {
                    Text(offer.declineTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.buttonHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(OfferButtonStyle(fill: palette.primaryText.opacity(0.1)))

                Button(action: accept) {
                    Text(offer.acceptTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.inkLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.buttonHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(OfferButtonStyle(fill: palette.ink))
            }
            .focusEffectDisabled()
        }
        .padding(14)
        .frame(width: MeetingOfferController.cardSize.width - 2,
               height: MeetingOfferController.cardSize.height - 2)
        .background(OfferSurface(palette: palette))
        .padding(1)
        .padding(MeetingOfferController.shadowMargin)
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
        // The card's own shadow, under it and cut out of it, as the
        // onboarding card's is (`IntroSurface`).
        .background {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
                .mask {
                    Rectangle()
                        .padding(-MeetingOfferController.shadowMargin)
                        .overlay { shape.blendMode(.destinationOut) }
                        .compositingGroup()
                }
        }
        // One hairline, a point outside the card's edge, as the onboarding
        // card has.
        .overlay(shape.inset(by: -1).strokeBorder(palette.outline, lineWidth: 0.5))
    }
}

#if DEBUG
#Preview("Meeting offer") {
    MeetingOfferView(offer: MeetingOffer(headline: "Take notes for “Weekly sync”?",
                                         detail: "Zoom is on a call. Both sides are transcribed on this Mac.",
                                         acceptTitle: "Take Notes", declineTitle: "Not Now"),
                     accept: {}, decline: {})
        .padding(30)
        .background(Color(nsColor: .underPageBackgroundColor))
}
#endif
