import SwiftUI
import ClioCore

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

    /// Interactive glass in a circle, for something that is not a Button
    /// but should look like a large glass one.
    @ViewBuilder
    func glassDisc() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle())
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

/// A document's ⋯, top right of the window. A flexible space pushes it
/// there: on macOS a placement alone puts it at the leading edge, beside
/// the title.
struct TrailingToolbarActions<Content: View>: ToolbarContent {
    @ViewBuilder var content: Content

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
            // On bare toolbar, like the title: no glass capsule of its own.
            ToolbarItem(placement: .automatic) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { content }
        }
    }
}

/// Who was invited, under the chevron beside the title: each one copies
/// their address, and all of them together.
struct AttendeesMenu: View {
    let attendees: [MeetingAttendee]

    private var emails: [String] { attendees.compactMap(\.email) }

    var body: some View {
        if attendees.isEmpty {
            Text("No one else invited")
        } else {
            ForEach(Array(attendees.enumerated()), id: \.offset) { _, person in
                if let email = person.email {
                    Button(person.declined ? "\(person.name) (declined)" : person.name) {
                        TextInjector.copy(email)
                    }
                } else {
                    Text(person.declined ? "\(person.name) (declined)" : person.name)
                }
            }
            if emails.count > 1 {
                Divider()
                Button("Copy All Emails") { TextInjector.copy(emails.joined(separator: ", ")) }
            }
        }
    }
}

/// The ⋯ top right of a meeting or a dictation: everything but Copy,
/// which stays along the foot.
struct MoreMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // A Menu on macOS ignores `buttonStyle(.glass)` and draws the
        // stock grey menu button; so the glass is drawn around a
        // borderless one, sized to the disc a large glass Button gets.
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 35, height: 35)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassDisc()
        .help("More")
        .accessibilityLabel("More")
    }
}

/// The onboarding card's ink, for the library's main buttons: black on
/// light, white on dark, the label in the opposite. Glass on macOS 26.
private struct InkButton: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        // In a window that is not active, macOS draws prominent glass
        // without its tint: an inverted label would be white on pale glass.
        // There the label takes the text's own colour instead.
        let inactive = activeState == .inactive
        content
            .foregroundStyle(inactive ? Color.primary : (dark ? Color.black : Color.white))
            .glassButton(prominent: true, tint: dark ? .white : .black)
    }
}

extension View {
    func inkButton() -> some View { modifier(InkButton()) }
}

/// Copy, as a glass disc the size of the ⋯ beside it.
struct CopyButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.fill.on.square.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .glassButton()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A document's controls, along its foot on glass: what it shows on the
/// left, what to do with it on the right. There is no toolbar; this is
/// where the toolbar's things went.
struct DocumentBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 0)
                trailing
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}
