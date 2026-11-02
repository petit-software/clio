import SwiftUI

// Liquid Glass, where macOS has it (26 and later), and the nearest thing
// before it: the pill, the cards and the windows all ask for glass through
// these, so the fallback is decided once.

extension View {
    /// A button on glass. Prominent buttons are filled with `tint` — the
    /// accent if none — and are the one thing on a surface to press.
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(tint)
            } else {
                buttonStyle(.glass).tint(tint)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).tint(tint)
        } else {
            buttonStyle(.bordered).tint(tint)
        }
    }

    /// Glass behind this view, in `shape`; a material before macOS 26.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .background(tint.map { $0.opacity(0.12) } ?? .clear, in: shape)
        }
    }
}

extension View {
    /// Content scrolling under the toolbar fades into it rather than being
    /// cut off at a line — the soft edge macOS 26 draws. Nothing before it.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// Pieces of glass close together, so they blend and morph as one — what
/// `GlassEffectContainer` is for. Nothing before macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A document's actions, top right of the window — the same spot whether a
/// meeting or a dictation is showing. A flexible space pushes them there:
/// on macOS a placement alone puts them at the leading edge, next to the
/// sidebar.
struct TrailingToolbarActions<Content: View>: ToolbarContent {
    @ViewBuilder var content: Content

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItemGroup(placement: .automatic) { content }
    }
}
