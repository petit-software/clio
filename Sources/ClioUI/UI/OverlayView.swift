import SwiftUI
import ClioCore

/// The dictation pill.
///
/// Proportions come from the design, measured off it rather than eyeballed:
/// a capsule whose every dimension is a fraction of its height, so the whole
/// thing scales from one number.
struct OverlayView: View {
    @Bindable var model: OverlayModel

    // MARK: Design

    /// The one dimension everything else derives from.
    static let height: CGFloat = 52
    /// Room around the pill for its shadow, so the panel does not clip it.
    static let shadowPadding: CGFloat = 14

    private var h: CGFloat { Self.height }

    @Environment(\.colorScheme) private var scheme

    /// The design's light surface, and its counterpart for a dark system.
    ///
    /// The pill hangs over other applications rather than inside a window, so
    /// it follows the system appearance: a light pill on a dark desktop reads
    /// as a foreign object, and glass that ignores the appearance ends up with
    /// black text on a dark blur.
    private static let lightFill = Color(red: 220/255, green: 220/255, blue: 219/255)
    private static let darkFill = Color(red: 58/255, green: 56/255, blue: 53/255)
    /// The record dot stays orange in both appearances — it is the one thing
    /// that has to read as "live" at a glance, and a black dot does not.
    private static let recordDot = Color(red: 241/255, green: 107/255, blue: 51/255)

    private var isDark: Bool { scheme == .dark }
    private var pillFill: Color { isDark ? Self.darkFill : Self.lightFill }
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
        .background { PillBackground(tint: pillFill, isDark: isDark) }
        .clipShape(Capsule())
        // The pill floats over other applications, and the backdrop is
        // whatever happens to be behind it. The shadow is what separates the
        // two on a light one.
        .shadow(color: .black.opacity(0.28), radius: h * 0.14, y: h * 0.05)
        .padding(Self.shadowPadding)
        .animation(.easeOut(duration: 0.18), value: model.state)
        .animation(.easeOut(duration: 0.12), value: model.isHovering)
    }

    // MARK: Pieces

    @ViewBuilder
    private var leading: some View {
        switch model.state {
        case .recording:
            Circle()
                .fill(Self.recordDot)
                .frame(width: h * 0.21, height: h * 0.21)
                .padding(.leading, h * 0.25)
                .padding(.trailing, h * 0.29)
        case .transcribing, .injecting:
            Spinner(diameter: h * 0.29, colour: ink)
                .padding(.leading, h * 0.31)
                .padding(.trailing, h * 0.26)
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: h * 0.22, weight: .bold))
                .foregroundStyle(ink)
                .padding(.leading, h * 0.31)
                .padding(.trailing, h * 0.26)
        case .idle, .failed:
            // Errors are the message alone; the capsule's own padding is the
            // only inset they need.
            Color.clear.frame(width: h * 0.31, height: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.state == .recording {
            LevelMeter(level: model.level, height: h, colour: ink)
            // Only in the last stretch, and only because being cut off
            // mid-sentence without warning is worse than a tidy pill.
            if model.isNearLimit {
                // The number alone. "left" is a word the user reads once and
                // then never again, and it doubles the width of the readout.
                Text(model.progress.display)
                    .font(.system(size: h * 0.21 + 2, weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(Self.recordDot)
                    .padding(.leading, h * 0.2)
            }
        } else {
            Text(label)
                .font(.system(size: h * 0.25, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if model.isCancellableByClick {
            CloseButton(diameter: h * 0.27,
                        fill: closeGrey,
                        glyph: pillFill,
                        emphasised: model.isHovering)
                .padding(.leading, h * 0.26)
                .padding(.trailing, h * 0.31)
        } else {
            Color.clear.frame(width: h * 0.31, height: 0)
        }
    }

    private var label: String {
        if let note = model.note { return note }
        switch model.state {
        case .transcribing: return "Transcribing"
        case .injecting: return "Pasting"
        case .finished: return "Done"
        case .failed(let message): return message
        case .idle, .recording: return ""
        }
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
private struct PillBackground: View {
    let tint: Color
    let isDark: Bool

    /// Enough tint to keep the label legible over any backdrop, and no more.
    /// Below roughly a third the pill stops being a surface and the text
    /// starts competing with whatever is behind it.
    private var fillOpacity: Double { isDark ? 0.32 : 0.30 }

    var body: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(tint.opacity(fillOpacity))
                .glassEffect(.regular.tint(tint.opacity(0.16)), in: Capsule())
        } else {
            Capsule()
                .fill(tint.opacity(fillOpacity))
                .background(.regularMaterial, in: Capsule())
        }
    }
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

    private static let weights: [CGFloat] = [0.31, 0.57, 0.18, 0.31, 0.18]

    var body: some View {
        let barWidth = height * 0.104
        HStack(alignment: .center, spacing: barWidth) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                let full = height * weight
                let floor = barWidth
                Capsule()
                    .fill(colour)
                    .frame(width: barWidth,
                           height: floor + (full - floor) * CGFloat(level))
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

#Preview("Long error") {
    OverlayView(model: overlayModel {
        $0.state = .failed("No model installed — open Settings ▸ Model to download one.")
    })
    .padding(20)
    .background(Color(red: 54/255, green: 52/255, blue: 49/255))
}
#endif
