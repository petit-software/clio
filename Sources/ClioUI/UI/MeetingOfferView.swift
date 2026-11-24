import AppKit
import SwiftUI
import ClioCore

/// "Take notes for Weekly sync?" — a small card when a call starts.
///
/// A non-activating panel, like the pill: it must never take focus from the
/// call the user is joining. It goes away on its own after half a minute,
/// since saying nothing is also an answer.
///
/// It goes where the day view goes and arrives as the day view does
/// (`DayPanelPlacement`): the corner or the centre Settings ▸ Day View
/// names, on the screen the pointer is on, growing out of that corner and
/// leaving the same way. The card for a call that is starting is the
/// exception in one respect — it is `prominent`: over the middle of the
/// day view, which it brings up with it (`AppCoordinator.holdDayForCall`),
/// and drawn larger.
@MainActor
final class MeetingOfferController {
    private var panel: NSPanel?
    private var presentation: OfferPresentation?
    private var timeout: Task<Void, Never>?
    /// Runs once when the card on screen goes, however it goes: a button,
    /// its time running out, another card taking its place.
    private var onGone: (() -> Void)?

    /// Where the day view goes, and where its card is while it is up.
    /// Asked each time a card shows.
    var dayPlacement: () -> (position: DayPanelPosition, dayCard: CGRect?) = { (.topRight, nil) }

    /// The card, with the point either side of it its hairline is drawn in.
    /// The width is the card's; the height is only the most it has been —
    /// each card is as tall as what it says (`show` measures it), so the
    /// two lines of "the call has ended" do not sit in the room an event
    /// and a wrapped line need.
    static let cardSize = CGSize(width: 340, height: 124)
    /// Room round the card for the shadow it casts: the card draws its
    /// own, as the onboarding card does, and the panel casts none.
    static let shadowMargin: CGFloat = 36
    /// How much larger the card for a call that is starting is drawn.
    static let prominentScale: CGFloat = 1.05

    /// A call app has opened its microphone: take notes for it?
    func show(title: String?, app: CallApp, event: MeetingEvent? = nil,
              accept: @escaping () -> Void, decline: @escaping () -> Void = {}) {
        show(MeetingOffer(
            headline: title.map { "Take notes for “\($0)”?" } ?? "Take notes for this call?",
            detail: "\(app.name) is on a call. Both sides are transcribed on this Mac.",
            acceptTitle: "Take Notes", declineTitle: "Not Now",
            event: event),
             accept: accept, decline: decline)
    }

    /// Shows a card. It goes after `timeout` seconds, with `onTimeout` if
    /// nothing was pressed — saying nothing is an answer too.
    func show(_ offer: MeetingOffer, prominent: Bool = false, timeout seconds: TimeInterval = 30,
              accept: @escaping () -> Void, decline: @escaping () -> Void = {},
              onTimeout: @escaping () -> Void = {}, onGone: @escaping () -> Void = {}) {
        // Whatever card was up is replaced, not walked off.
        remove()
        self.onGone = onGone
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

        // As tall as this card's own content, measured before it is shown.
        let fitted = NSHostingView(rootView: view).fittingSize
        let card = CGSize(width: Self.cardSize.width,
                          height: fitted.height > 0 ? fitted.height : Self.cardSize.height)
        let scale = prominent ? Self.prominentScale : 1
        // The shadow grows with the card.
        let margin = (Self.shadowMargin * scale).rounded(.up)
        let size = CGSize(width: (card.width * scale).rounded(.up) + 2 * margin,
                          height: (card.height * scale).rounded(.up) + 2 * margin)

        let (position, dayCard) = dayPlacement()
        // Over the middle of the day view, the card grows from its own
        // middle; anywhere else, from the corner it is in.
        let over = prominent ? dayCard : nil
        let presentation = OfferPresentation(
            position: over != nil ? .center : position, scale: scale,
            size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin),
            margin: margin)
        let host = FirstClickHostingView(rootView: OfferPresentationView(presentation: presentation,
                                                                         card: view))
        let panel = OfferPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card's own shadow (`OfferSurface`), which is where the card
        // is; the window's is wherever the card was when it was taken.
        panel.hasShadow = false
        // One above the day view, which a card can share a corner with.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.contentView = host
        panel.setContentSize(size)

        if let over {
            panel.setFrameOrigin(NSRect(x: over.midX - size.width / 2, y: over.midY - size.height / 2,
                                        width: size.width, height: size.height).integral.origin)
        } else if let visible = DayPanelPlacement.visibleFrame() {
            panel.setFrameOrigin(NSRect(
                origin: DayPanelPlacement.origin(for: size, in: visible, position: position,
                                                 shadowMargin: margin),
                size: size).integral.origin)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.presentation = presentation
        // A runloop later, so the first frame is drawn in the hidden pose
        // and there is something to animate from.
        DispatchQueue.main.async {
            withAnimation(DayPanelPlacement.entrance) { presentation.isShown = true }
        }

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

    /// Puts the card away as the day view goes: shrinking back to where it
    /// came from. It stops counting as showing at once.
    func dismiss() {
        timeout?.cancel()
        timeout = nil
        guard let panel, let presentation else { return }
        self.panel = nil
        self.presentation = nil
        gone()
        withAnimation(DayPanelPlacement.exit) { presentation.isShown = false }
        Task {
            try? await Task.sleep(for: DayPanelPlacement.exitTime)
            panel.orderOut(nil)
        }
    }

    /// Takes the card away with no exit, for the one that replaces it.
    private func remove() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
        presentation = nil
        gone()
    }

    private func gone() {
        let ended = onGone
        onGone = nil
        ended?()
    }
}

/// How a card is on screen: where, how large, and whether it has arrived.
@MainActor
@Observable
final class OfferPresentation {
    let position: DayPanelPosition
    let scale: CGFloat
    /// The card's size on screen, scale and all.
    let size: CGSize
    /// Clear room round it for its shadow.
    let margin: CGFloat
    /// Drives the entrance and exit; the window itself stays opaque to them.
    var isShown = false

    init(position: DayPanelPosition, scale: CGFloat, size: CGSize, margin: CGFloat) {
        self.position = position
        self.scale = scale
        self.size = size
        self.margin = margin
    }
}

/// A card at its place in its window, arriving and leaving as the day view
/// does.
private struct OfferPresentationView: View {
    let presentation: OfferPresentation
    let card: MeetingOfferView

    var body: some View {
        card
            // Its size on screen first, about its own middle, so the room
            // it takes is the room it is drawn in.
            .scaleEffect(presentation.scale)
            .frame(width: presentation.size.width, height: presentation.size.height)
            .scaleEffect(presentation.isShown ? 1 : DayPanelPlacement.hiddenScale,
                         anchor: DayPanelPlacement.anchor(for: presentation.position))
            .offset(y: presentation.isShown
                    ? 0 : DayPanelPlacement.entryOffset(for: presentation.position))
            .opacity(presentation.isShown ? 1 : 0)
            .padding(presentation.margin)
    }
}

/// Non-activating: a click makes the card key for that click without
/// making Clio the active app, so the call keeps its place in front.
private final class OfferPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// As the day view's panel: its clear margin may go under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
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
    /// The calendar event the card is about. With one, the card shows it
    /// as the calendar would — its calendar's colour, its name, when and
    /// where — in place of the headline and the line under it.
    var event: MeetingEvent?
    /// Whether the event's link is offered on its own, beside it: before
    /// the call is joined, not once a call app is already on it.
    var offersLink = false
}

struct MeetingOfferView: View {
    static let buttonHeight: CGFloat = 32

    let offer: MeetingOffer
    let accept: () -> Void
    let decline: () -> Void
    var openLink: (URL) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    private var palette: IntroPalette { IntroPalette(colorScheme: colorScheme) }

    /// The event as a calendar shows it: a bar in its calendar's colour,
    /// its name, then when and where on one line — and, before the call
    /// is joined, its link on a button of the same colour.
    private func eventBlock(_ event: MeetingEvent) -> some View {
        let color = event.calendarColor.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue)
        } ?? palette.secondaryText
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let when = "\(event.start.formatted(time)) – \(event.end.formatted(time))"
        return HStack(spacing: 10) {
            Capsule()
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(event.joinURL.map { "\(when) · \($0.absoluteString)" } ?? when)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if offer.offersLink, let url = event.joinURL {
                Button { openLink(url) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(color, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Join the call without taking notes")
            }
        }
        .frame(height: 34)
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        // The row is the event as its calendar draws it: a wash of the
        // calendar's colour behind it, the bar the same colour at full.
        .background(color.opacity(colorScheme == .dark ? 0.22 : 0.14),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        // White under the wash, so the colour is the calendar's own on
        // paper and not whatever the glass is sampling behind the card.
        // In the dark a lift of the surface instead: white there would
        // take the white name with it.
        .background(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let event = offer.event {
                eventBlock(event)
            } else {
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
        // The card's width, and whatever height that comes to.
        .frame(width: MeetingOfferController.cardSize.width - 2)
        .fixedSize(horizontal: false, vertical: true)
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
