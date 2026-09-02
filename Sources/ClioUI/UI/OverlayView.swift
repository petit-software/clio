import SwiftUI
import ClioCore

/// The dictation pill.
///
/// Proportions come from the design, measured off it rather than eyeballed:
/// a capsule whose every dimension is a fraction of its height, so the whole
/// thing scales from one number.
struct OverlayView: View {
    @Bindable var model: OverlayModel

    /// True on the copy the controller measures and never shows. It always
    /// renders the pill open, so the window is sized for the pill at rest
    /// rather than for whatever point of its entrance the real one is at.
    var isMeasuring = false

    private var shown: Bool { isMeasuring || model.isShown }

    // MARK: Design

    /// The one dimension everything else derives from, at the design's size.
    static let height: CGFloat = 52
    /// Room around the pill for its shadow, so the panel does not clip it.
    static let shadowPadding: CGFloat = 14

    /// The height actually drawn: the design's, times the size chosen in
    /// Settings. Everything below is a fraction of this, so the user's choice
    /// grows the dot, the meter, the text and the ✕ together.
    private var h: CGFloat { Self.height * CGFloat(model.size.scale) }

    @Environment(\.colorScheme) private var scheme

    /// The design's light surface, and its counterpart for a dark system.
    ///
    /// The pill hangs over other applications rather than inside a window, so
    /// it follows the system appearance: a light pill on a dark desktop reads
    /// as a foreign object, and glass that ignores the appearance ends up with
    /// black text on a dark blur.
    // Claro's popup surface, borrowed wholesale so the two read as siblings.
    // Its own values were 220/220/219 and 58/56/53 — kept below for reference
    // if this turns out to be too stark for a HUD that appears unbidden.
    private static let lightFill = Color(red: 0.98, green: 0.98, blue: 0.97)
    private static let darkFill = Color(red: 0.03, green: 0.03, blue: 0.03)
    /// The record dot stays orange in both appearances — it is the one thing
    /// that has to read as "live" at a glance, and a black dot does not.
    private static let recordDot = Color(red: 241/255, green: 107/255, blue: 51/255)

    /// Every word in the pill. Named rather than repeated, so a label added
    /// later cannot quietly arrive at a different weight from the rest.
    private static let textWeight: Font.Weight = .semibold

    private var isDark: Bool { scheme == .dark }
    private var pillFill: Color { isDark ? Self.darkFill : Self.lightFill }
    private var glassTint: Color {
        isDark ? Color.black.opacity(0.82) : Color.white.opacity(0.84)
    }
    /// A hairline, which is what separates the surface from a bright backdrop
    /// once the fill is translucent.
    private var outline: Color {
        isDark ? Color.white.opacity(0.24) : Color.black.opacity(0.42)
    }
    private var ambientShadow: Color {
        isDark ? Color.black.opacity(0.34) : Color.black.opacity(0.08)
    }
    private var contactShadow: Color {
        isDark ? Color.black.opacity(0.24) : Color.black.opacity(0.08)
    }
    /// Text and level bars: the design's black, inverted for dark.
    private var ink: Color { isDark ? Color(white: 0.96) : .black }
    private var closeGrey: Color {
        isDark ? Color(white: 0.62) : Color(red: 158/255, green: 158/255, blue: 157/255)
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
            content
            trailing
        }
        .frame(height: h)
        // The entrance. The capsule begins as a circle at its own centre and
        // springs open to fit; on the way out it closes again. The content
        // keeps its size and stays centred in the stack, overflowing the
        // clip — invisible, since every element fades on its own (see
        // Arrival) and is only fully there once the capsule is.
        .frame(width: shown ? nil : h)
        .background {
            PillBackground(tint: pillFill,
                           glassTint: glassTint,
                           outline: outline,
                           surface: model.surface)
        }
        .clipShape(Capsule())
        // Shadows go OUTSIDE the clip. Inside the background they were drawn
        // and then clipped to the capsule, which removes them completely —
        // a shadow lives entirely beyond the shape casting it.
        .shadow(color: ambientShadow, radius: 8, x: 0, y: 3)
        .shadow(color: contactShadow, radius: 2, x: 0, y: 1)
        .padding(Self.shadowPadding)
        // Between states: the width settles without overshoot, since the
        // window it lives in is only ever grown ahead of it, never with it.
        .animation(.smooth(duration: 0.3), value: model.state)
        // A size change is deliberately NOT animated: the window is fitted to
        // the new size at once, and a pill still shrinking inside a window
        // that has already shrunk gets clipped on the way.
        .animation(.easeOut(duration: 0.12), value: model.isHovering)
        // In and out, from the centre. The shape springs open a little past
        // its size and settles; it closes without bounce, because the next
        // thing the user is looking at is their own text.
        .scaleEffect(shown ? 1 : 0.92)
        .animation(shown ? Self.entrance : Self.exit, value: shown)
        // The fade is quicker than the shape, on both ends, so the pill is
        // never a ghost: it is either arriving solid or already gone.
        .opacity(shown ? 1 : 0)
        .animation(shown ? .easeOut(duration: 0.16) : .easeIn(duration: 0.14),
                   value: shown)
        // The hosting window is measured from this view but may be wider
        // while a state change settles — so the pill holds to the edge it is
        // anchored on, and the slack sits on the far side where it is invisible.
        .frame(maxWidth: .infinity,
               alignment: Alignment(horizontal: horizontalAnchor, vertical: .center))
    }

    // MARK: Entrance

    /// The shape's arrival and departure. The elements inside have their own,
    /// see `Arrival`; the controller's hideDuration is derived from `exit`.
    static let entrance: Animation = .spring(duration: 0.42, bounce: 0.22)
    static let exit: Animation = .easeIn(duration: 0.18)

    /// The edge the pill is pinned to, from where it sits on screen.
    ///
    /// Centre until the entrance has settled: the window is exactly the
    /// pill's size at that point, and centring is what lets the capsule open
    /// from its middle rather than from one end. Afterwards the anchored edge,
    /// so a state change holds it still — see the frame above.
    private var horizontalAnchor: HorizontalAlignment {
        guard model.isSettled else { return .center }
        switch model.position {
        case .topLeft, .bottomLeft: return .leading
        case .topRight, .bottomRight: return .trailing
        case .topCenter, .bottomCenter, .nearCursor, .none: return .center
        }
    }

    /// How one element gives way to another at a state change. The outgoing
    /// one is gone quickly; the incoming one arrives a beat later, small, so
    /// the two are never both half there — the capsule has already begun to
    /// move by then, and the new content lands in it rather than on top of
    /// what it replaced.
    private static let swap: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.85))
            .animation(.spring(duration: 0.32, bounce: 0.2).delay(0.08)),
        removal: .opacity.combined(with: .scale(scale: 0.9))
            .animation(.easeIn(duration: 0.1)))

    /// How the pieces come in: a beat after the capsule starts to open, in
    /// order from left to right, each with its own small spring.
    private enum Beat {
        static let leading = 0.05
        static let meter = 0.08
        static let meterStep = 0.03
        static let label = 0.10
        static let trailing = 0.17
    }

    // MARK: Pieces

    @ViewBuilder
    private var leading: some View {
        switch model.state {
        case .idle, .failed, .emptyResult:
            // Errors, "nothing heard", and the position preview are the message
            // alone; the capsule's own padding is the only inset they need.
            Color.clear.frame(width: h * 0.31, height: 0)
        case .recording, .transcribing, .injecting, .finished:
            // One slot with one frame for the dot, the spinner and the tick,
            // so a state change swaps the glyph in place. Each with its own
            // padding, the left end of the pill re-laid itself out at every
            // change, and the swap read as a lurch rather than a crossfade.
            ZStack {
                switch model.state {
                case .recording:
                    Circle()
                        .fill(Self.recordDot)
                        .frame(width: h * 0.21, height: h * 0.21)
                        // A touch in from the slot's centre. The dot is small
                        // and round where the others fill the slot, and at
                        // the same centre it looks closer to the edge.
                        .offset(x: 3)
                        .modifier(Arrival(shown: shown, after: Beat.leading, from: 0.2))
                        .transition(Self.swap)
                case .transcribing, .injecting:
                    Spinner(diameter: h * 0.29, colour: ink)
                        .modifier(Arrival(shown: shown, after: Beat.leading, from: 0.4))
                        .transition(Self.swap)
                case .finished:
                    Image(systemName: model.transcriptIsOnClipboard
                          ? "square.fill.on.square.fill" : "checkmark")
                        .font(.system(size: h * 0.22, weight: .bold))
                        .foregroundStyle(ink)
                        .modifier(Arrival(shown: shown, after: Beat.leading, from: 0.4))
                        .transition(Self.swap)
                case .idle, .failed, .emptyResult:
                    EmptyView()
                }
            }
            .frame(width: h * 0.29, height: h * 0.29)
            .padding(.leading, h * 0.31)
            .padding(.trailing, h * 0.26)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.state == .recording && !model.isPreview {
            // Dimmed and still until audio is actually flowing. Bars frozen at
            // zero would read as a microphone that is not working.
            LevelMeter(level: model.captureIsLive ? model.level : 0,
                       height: h, colour: ink, shown: shown)
                .opacity(model.captureIsLive ? 1 : 0.45)
                .transition(Self.swap)
            // Only in the last stretch, and only because being cut off
            // mid-sentence without warning is worse than a tidy pill.
            if model.isNearLimit {
                // The number alone. "left" is a word the user reads once and
                // then never again, and it doubles the width of the readout.
                Text(model.progress.display)
                    .font(.system(size: h * 0.21 + 2, weight: Self.textWeight,
                                  design: .monospaced))
                    .foregroundStyle(Self.recordDot)
                    .modifier(Arrival(shown: shown, after: Beat.label, rise: 3))
                    .transition(Self.swap)
                    .padding(.leading, h * 0.2)
            }
        } else {
            Text(label)
                .font(.system(size: h * 0.25, weight: Self.textWeight))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .modifier(Arrival(shown: shown, after: Beat.label, from: 0.96, rise: 3))
                // A new label is a new view, so it comes and goes like every
                // other element rather than crossfading in place: two strings
                // of different lengths fading through each other read as a
                // smudge. Only the capsule's width carries over.
                .id(label)
                .transition(Self.swap)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if model.isCancellableByClick && !model.isPreview {
            CloseButton(diameter: h * 0.27,
                        fill: closeGrey,
                        glyph: pillFill,
                        emphasised: model.isHovering)
                .modifier(Arrival(shown: shown, after: Beat.trailing, from: 0.3))
                .transition(Self.swap)
                .padding(.leading, h * 0.26)
                .padding(.trailing, h * 0.31)
        } else {
            Color.clear.frame(width: trailingInset, height: 0)
        }
    }

    /// The right-hand inset when nothing sits there. Wider for a result,
    /// which has its glyph on the left: with the same inset on both sides the
    /// words ended closer to their edge than the glyph began from its own.
    private var trailingInset: CGFloat {
        if case .finished = model.state { return h * 0.44 }
        return h * 0.31
    }

    private var label: String {
        if model.isPreview { return "Preview" }
        if let note = model.note { return note }
        switch model.state {
        // Injecting is drawn as transcribing on purpose. It lasts about
        // 150 ms, and a pill that said "Pasting" for that long was seen as a
        // flicker between "Transcribing" and "Copied", never as a word.
        case .transcribing, .injecting: return "Transcribing"
        case .finished:
            return model.transcriptIsOnClipboard ? "Copied to clipboard" : "Pasted"
        case .failed(let message): return message
        case .emptyResult(let message): return message
        case .idle, .recording: return ""
        }
    }
}

/// One element's own way in and out.
///
/// In: a small spring from a fraction of its size, `after` a beat, so the
/// pieces of the pill land one after another rather than as a block. Out:
/// a plain fade, quicker than the capsule closing around it, so nothing is
/// still visible when the shape catches up with it.
private struct Arrival: ViewModifier {
    let shown: Bool
    let after: Double
    var from: CGFloat = 0.5
    var rise: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : from)
            .offset(y: shown ? 0 : rise)
            .opacity(shown ? 1 : 0)
            .animation(shown ? .spring(duration: 0.36, bounce: 0.32).delay(after)
                             : .easeOut(duration: 0.1),
                       value: shown)
    }
}

/// The pill's surface: glass where the system has it, a material where it
/// does not.
///
/// The tint is not decoration. The design is black text on a light pill, and
/// glass takes its colour from whatever happens to be behind it — over a dark
/// window the pill would go dark and the label would disappear. Keeping it
/// biased light means the design holds over any backdrop, which is the whole
/// difficulty of a panel that floats above other applications.
/// The pill's surface and its hairline. The shadows are NOT here — they are
/// applied outside the capsule clip, because anything drawn in a background
/// gets clipped with it and a shadow lives entirely outside its own shape.
private struct PillBackground: View {
    let tint: Color
    let glassTint: Color
    let outline: Color
    let surface: PillSurface

    var body: some View {
        let shape = Capsule()

        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(tint.opacity(surface.opacity))
                    .glassEffect(glass.tint(glassTint), in: shape)
            } else {
                shape
                    .fill(tint.opacity(surface.opacity))
                    .background(surface.fallbackMaterial, in: shape)
            }
        }
        .overlay(shape.strokeBorder(outline, lineWidth: 0.5))
    }

    @available(macOS 26.0, *)
    private var glass: Glass { surface.isClear ? .clear : .regular }
}

/// The spinner, drawn rather than an `NSProgressIndicator`.
///
/// Two reasons the system one will not do: on macOS it ignores `.tint`, so it
/// cannot be coloured to match the label; and it renders as a placeholder
/// glyph in any static snapshot, which makes the design impossible to check
/// against the drawing.
private struct Spinner: View {
    let diameter: CGFloat
    let colour: Color

    private static let spokes = 12

    @State private var turning = false

    var body: some View {
        ZStack {
            ForEach(0..<Self.spokes, id: \.self) { index in
                Capsule()
                    .fill(colour)
                    // Fading around the ring is what reads as motion; without
                    // it a spinning ring of identical spokes looks static.
                    .opacity(0.25 + 0.75 * Double(index) / Double(Self.spokes))
                    .frame(width: diameter * 0.13, height: diameter * 0.3)
                    .offset(y: -diameter * 0.34)
                    .rotationEffect(.degrees(Double(index) / Double(Self.spokes) * 360))
            }
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(turning ? 360 : 0))
        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                   value: turning)
        .onAppear { turning = true }
    }
}

/// The ✕ that abandons the run.
///
/// Always visible while something is cancellable — the design does not hide it
/// behind a hover, and a control you cannot see is one nobody uses.
private struct CloseButton: View {
    let diameter: CGFloat
    let fill: Color
    let glyph: Color
    let emphasised: Bool

    var body: some View {
        ZStack {
            Circle().fill(emphasised ? fill.opacity(1) : fill.opacity(0.85))
            Image(systemName: "xmark")
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(glyph)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(emphasised ? 1.12 : 1)
    }
}

/// The live level, as the five bars in the design.
///
/// Every bar shares one centre line and keeps its share of the silhouette, so
/// the meter breathes rather than jumping — the same rule as the menu bar mark.
private struct LevelMeter: View {
    let level: Float
    let height: CGFloat
    let colour: Color
    /// Off, the bars are flat and gone; on, they rise one after another.
    var shown = true

    private static let weights: [CGFloat] = [0.31, 0.57, 0.18, 0.31, 0.18]

    var body: some View {
        let barWidth = height * 0.104
        HStack(alignment: .center, spacing: barWidth) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { index, weight in
                let full = height * weight
                let floor = barWidth
                Capsule()
                    .fill(colour)
                    .frame(width: barWidth,
                           height: floor + (full - floor) * CGFloat(level))
                    // Each bar on its own beat, from the centre line up.
                    .scaleEffect(y: shown ? 1 : 0.15)
                    .opacity(shown ? 1 : 0)
                    .animation(shown
                               ? .spring(duration: 0.36, bounce: 0.34)
                                   .delay(0.08 + 0.03 * Double(index))
                               : .easeOut(duration: 0.1),
                               value: shown)
            }
        }
        .frame(height: height * 0.57)
        .animation(.linear(duration: 0.06), value: level)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func overlayModel(_ configure: (OverlayModel) -> Void) -> OverlayModel {
    let model = OverlayModel()
    model.isShown = true
    configure(model)
    return model
}

/// The three states the design specifies, on the ground it was drawn against.
#Preview("Designed states") {
    VStack(spacing: 4) {
        OverlayView(model: overlayModel { $0.state = .recording; $0.level = 0.75 })
        OverlayView(model: overlayModel { $0.state = .transcribing })
        OverlayView(model: overlayModel { $0.state = .failed("Nothing returned") })
    }
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}

/// The pill floats over whatever is behind it, so it has to hold up on more
/// than the dark card it was drawn on.
#Preview("Over other backdrops") {
    VStack(spacing: 4) {
        OverlayView(model: overlayModel { $0.state = .recording; $0.level = 0.5 })
        OverlayView(model: overlayModel { $0.state = .transcribing })
    }
    .padding(20)
    .background(LinearGradient(colors: [.white, .indigo],
                               startPoint: .top, endPoint: .bottom))
}

#Preview("Level sweep") {
    VStack(spacing: 2) {
        ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
            OverlayView(model: overlayModel {
                $0.state = .recording; $0.level = Float(level)
            })
        }
    }
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}

/// Near the cap the pill grows a countdown — the one thing the design does not
/// cover, kept because being cut off mid-sentence without warning is worse.
#Preview("Near the limit") {
    VStack(spacing: 4) {
        OverlayView(model: overlayModel {
            $0.state = .recording; $0.level = 0.6
            $0.progress = RecordingProgress(elapsed: 588, limit: 600)
        })
        OverlayView(model: overlayModel {
            $0.state = .finished("x"); $0.note = "Stopped at the 10:00 limit"
        })
    }
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}

/// What the pill says when it is over, which depends on where the words went.
#Preview("Finished") {
    VStack(spacing: 4) {
        OverlayView(model: overlayModel {
            $0.state = .finished("x"); $0.transcriptIsOnClipboard = true
        })
        OverlayView(model: overlayModel { $0.state = .finished("x") })
    }
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}

/// What Settings flashes when the overlay position changes.
#Preview("Position preview") {
    OverlayView(model: overlayModel { $0.isPreview = true })
        .padding(20)
        .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}

/// The three sizes Settings offers. Every dimension is a fraction of the
/// height, so the larger ones should look like the same pill, closer.
#Preview("Sizes") {
    VStack(spacing: 4) {
        ForEach(PillSize.allCases, id: \.self) { size in
            OverlayView(model: overlayModel {
                $0.state = .recording; $0.level = 0.75; $0.captureIsLive = true
                $0.size = size
            })
            OverlayView(model: overlayModel { $0.state = .transcribing; $0.size = size })
        }
    }
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}

#Preview("Long error") {
    OverlayView(model: overlayModel {
        $0.state = .failed("No model installed — open Settings ▸ Model to download one.")
    })
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}
#endif
