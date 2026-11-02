import SwiftUI

// The intro card's materials, taken from Fino's Access popup so the two
// apps' first screens read as one family: a glass sheet with 32pt corners
// and a hairline just outside it, a glass ✕ in the top-left corner, and
// capsule buttons in the appearance's own ink.

/// Every colour on the card, for one appearance.
struct IntroPalette {
    let colorScheme: ColorScheme
    private var isDark: Bool { colorScheme == .dark }

    var surface: Color {
        isDark ? Color(red: 0.03, green: 0.03, blue: 0.03)
               : Color(red: 0.98, green: 0.98, blue: 0.97)
    }
    var glassTint: Color { isDark ? .black.opacity(0.82) : .white.opacity(0.84) }
    var outline: Color { isDark ? .white.opacity(0.24) : .black.opacity(0.42) }

    var primaryText: Color {
        isDark ? Color(red: 0.96, green: 0.96, blue: 0.96)
               : Color(red: 0.04, green: 0.04, blue: 0.04)
    }
    var secondaryText: Color { isDark ? .white.opacity(0.33) : .black.opacity(0.42) }

    /// The prominent button's fill: black on light, white on dark.
    var ink: Color { isDark ? .white : .black }
    var inkLabel: Color { isDark ? .black : .white }
}

/// The sheet itself. Glass on macOS 26, the same colour solid before it.
struct IntroSurface: View {
    let palette: IntroPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IntroView.cornerRadius, style: .continuous)

        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(palette.surface.opacity(0.58))
                    .glassEffect(.regular.tint(palette.glassTint), in: shape)
            } else {
                shape.fill(palette.surface)
            }
        }
        // `strokeBorder` draws inside its shape, which would sit the hairline
        // within the card's edge. Grown by a point — still concentric — it
        // sits just outside, which is why the window is a point larger than
        // the card on every side.
        .overlay(
            shape
                .inset(by: -1)
                .strokeBorder(palette.outline, lineWidth: 0.5))
    }
}

/// The card's buttons: a capsule, glass on macOS 26.
enum IntroGlassButtonKind {
    /// The card's one main button, in ink.
    case prominent
    /// Everything else: clear glass, the label in the text colour.
    case utility
}

extension View {
    @ViewBuilder
    func introGlassButton(_ kind: IntroGlassButtonKind, palette: IntroPalette) -> some View {
        if #available(macOS 26.0, *) {
            switch kind {
            case .prominent:
                // Not `.glassProminent`: that one draws a rounded rectangle
                // whatever border shape it is given, and AppKit's blue focus
                // ring with it, which `.focusEffectDisabled` does not reach.
                // The card draws its own ring (`IntroFocusRing`).
                self.buttonStyle(IntroProminentButtonStyle(palette: palette))
                    .focusEffectDisabled()
            case .utility:
                self.buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .focusEffectDisabled()
            }
        } else {
            self.buttonStyle(IntroCapsuleButtonStyle(
                    background: kind == .prominent
                        ? palette.ink
                        : palette.secondaryText.opacity(0.35)))
                .focusEffectDisabled()
        }
    }
}

/// What on the card has keyboard focus. The main button takes it whenever a
/// step appears, so Return and Space both act on it and the ring says so;
/// the ✕ has it only when tabbed to.
enum IntroFocus: Hashable {
    case main
    case close
}

/// The card's own focus ring, drawn instead of the system's: 2pt in the text
/// colour, with 4pt of the card showing between it and the control.
private struct IntroFocusRing<S: InsettableShape>: View {
    let shape: S
    let palette: IntroPalette
    static var gap: CGFloat { 4 }
    static var lineWidth: CGFloat { 2 }

    var body: some View {
        shape
            .inset(by: -(Self.gap + Self.lineWidth))
            .strokeBorder(palette.primaryText, lineWidth: Self.lineWidth)
            .allowsHitTesting(false)
    }
}

/// A full-width capsule with one line of text: Get Started, Allow
/// Microphone, Start Dictating.
struct IntroMainButton: View {
    let title: String
    let palette: IntroPalette
    var focus: FocusState<IntroFocus?>.Binding
    /// Dimmed, and pressing it does nothing — but still enabled, so it keeps
    /// focus. A disabled button lets go of it, and macOS hands it to the ✕.
    var isWaiting = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.inkLabel)
                .lineLimit(1)
                .contentTransition(.opacity)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .introGlassButton(.prominent, palette: palette)
        .opacity(isWaiting ? 0.45 : 1)
        .animation(.easeOut(duration: 0.18), value: isWaiting)
        .keyboardShortcut(.defaultAction)
        .focused(focus, equals: .main)
        .focusEffectDisabled()
        .overlay {
            if isEnabled, focus.wrappedValue == .main {
                IntroFocusRing(shape: Capsule(), palette: palette)
            }
        }
    }
}

/// The ✕ in the card's corner: a small glass disc.
struct IntroCloseButton: View {
    let palette: IntroPalette
    var focus: FocusState<IntroFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .frame(width: 36, height: 36)
        }
        .frame(width: 36, height: 36)
        .buttonStyle(IntroCircularGlassButtonStyle())
        .focusEffectDisabled()
        .focused(focus, equals: .close)
        .overlay {
            if focus.wrappedValue == .close {
                IntroFocusRing(shape: Circle(), palette: palette)
            }
        }
        .help("Close")
        .accessibilityLabel("Close")
    }
}

/// The main button: a capsule of ink, glass over it on macOS 26 so it has
/// the same rim of light as everything else on the card.
private struct IntroProminentButtonStyle: ButtonStyle {
    let palette: IntroPalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .background {
                if #available(macOS 26.0, *) {
                    shape
                        .fill(palette.ink)
                        .glassEffect(.regular.tint(palette.ink).interactive(), in: shape)
                } else {
                    shape.fill(palette.ink)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Before macOS 26: a plain capsule in the given colour.
private struct IntroCapsuleButtonStyle: ButtonStyle {
    let background: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .background(background, in: Capsule())
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct IntroCircularGlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = Circle()
        configuration.label
            .contentShape(shape)
            .background {
                Group {
                    if #available(macOS 26.0, *) {
                        shape
                            .fill(fill(pressed: configuration.isPressed))
                            .glassEffect(.regular.tint(glassTint), in: shape)
                    } else {
                        shape.fill(fill(pressed: configuration.isPressed))
                    }
                }
            }
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
            .clipShape(shape)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var isDark: Bool { colorScheme == .dark }

    private func fill(pressed: Bool) -> Color {
        isDark ? .black.opacity(pressed ? 0.64 : 0.52)
               : .white.opacity(pressed ? 0.34 : 0.24)
    }

    private var glassTint: Color { isDark ? .black.opacity(0.72) : .white.opacity(0.72) }
    private var border: Color { isDark ? .white.opacity(0.14) : .white.opacity(0.36) }
}
