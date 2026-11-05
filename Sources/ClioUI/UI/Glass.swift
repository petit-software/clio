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

    /// The same in a capsule.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// A capsule along a foot — the pane pull-down, the day control — the
    /// height of the discs beside it, so every control on either foot is one
    /// size: 35 points, 14 in from each end, on interactive glass.
    func footCapsule() -> some View {
        padding(.horizontal, 14)
            .frame(height: 35)
            .glassCapsule()
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
    /// Settings has it; a document has `nativeTopEdge`.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// The toolbar's own edge: as content scrolls under it, macOS 26 draws
    /// the translucent band every other app's toolbar has. The library's
    /// documents had the soft fade for a while, and it read as a page
    /// without a toolbar.
    @ViewBuilder
    func nativeTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.automatic, for: .top)
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

/// What scrolls under a bar fades into the surface before it reaches the
/// controls: a blur, then the window's own colour, so the end of the fade is
/// the sidebar or the page and not a frost of its own. Solid at `edge`.
/// The sidebar's foot and a page's top share it, so the two match.
struct EdgeFade: View {
    var edge: VerticalEdge

    var body: some View {
        let from: UnitPoint = edge == .bottom ? .top : .bottom
        let to: UnitPoint = edge == .bottom ? .bottom : .top
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.5)],
                                   startPoint: from, endPoint: to)
                }
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: Color(nsColor: .windowBackgroundColor), location: 0.7)],
                           startPoint: from, endPoint: to)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The fade under a page's toolbar. The title bar is transparent — its
    /// own backdrop is a hard-edged band nothing can soften — so this is
    /// what keeps the title readable over the text passing under it.
    func pageTopFade() -> some View {
        overlay(alignment: .top) {
            EdgeFade(edge: .top)
                .frame(height: 96)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// The chevron that says a control opens or steps — the pane pull-down,
/// the participants, the day — one grey and one weight wherever it is. A
/// fraction of the ink, as the pill's microphone chevron is, so it follows
/// the appearance.
struct Chevron: View {
    var icon: LibraryIcon = .chevronDown
    /// The chevron's long side, in points: across for the pull-downs, up
    /// for the day's arrows.
    var size: CGFloat = 10

    static let colour = Color.primary.opacity(0.38)

    var body: some View {
        Glyph(icon: icon, size: size, cropped: true)
            .foregroundStyle(Self.colour)
    }
}

/// Which of a meeting's panes is showing, as a pull-down on glass: the
/// name and one chevron, not the popup's pair. Glass drawn around a plain
/// menu, as the ⋯ is, since a Menu ignores the glass button style.
struct PaneMenu: View {
    let panes: [MeetingView.Pane]
    @Binding var pane: MeetingView.Pane

    var body: some View {
        Menu {
            Picker("Show", selection: $pane) {
                ForEach(panes) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(pane.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Chevron()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 35)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, -14)
        .footCapsule()
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
            Glyph(icon: .ellipsis, size: 20)
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

/// Copy, as a glass disc the size of the ⋯, its glyph in the chevrons'
/// grey. Glass drawn around a plain button, as the ⋯ is: the glass button
/// style recolours its label, and left this one a grey of its own.
struct CopyButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(icon: .copy, size: 20)
                .foregroundStyle(Chevron.colour)
                .frame(width: 35, height: 35)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassDisc()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A document's controls, along its foot on glass: what it shows on the
/// left, what to do with it on the right, and — for a meeting being
/// recorded — the recorder in the middle. There is no toolbar; this is
/// where the toolbar's things went.
struct DocumentBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
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
        // The middle is laid over the bar, centred on the page, and not in
        // the glass group: inside it, the recorder's own surface and
        // everything on it were blended into the group's glass and washed
        // out to nearly nothing.
        .overlay { center }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        // What scrolls under the bar fades into the page before it reaches
        // the controls — the sidebar's foot, across the split.
        .background {
            EdgeFade(edge: .bottom)
                .padding(.top, -28)
        }
    }
}

extension DocumentBar where Center == EmptyView {
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: leading, center: { EmptyView() }, trailing: trailing)
    }
}
