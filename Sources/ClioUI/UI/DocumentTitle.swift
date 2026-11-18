import SwiftUI
import ClioCore

/// A document's name and date, where the window's title would be: the
/// name edited in place, no wider than `nameWidth`; under it the date; and
/// under that how long it ran and, as a dropdown of its own, who was
/// invited. Drawn by hand because the window's own title cannot take a
/// menu when it is bridged from a hosting view — `toolbarTitleMenu` showed
/// nothing.
struct DocumentTitle: View {
    @Binding var title: String
    var isEditable = true
    /// "When · how long": the part before the first " · " is the date's
    /// line, the rest goes on the line under it with who was invited.
    let subtitle: String
    /// Nil leaves the chevron out — a dictation has no one invited.
    var attendees: [MeetingAttendee]?

    /// The most room a name takes. A longer one is cut off there, with
    /// the rest a click and an arrow key away, rather than pushing the
    /// search button off the toolbar.
    static let nameWidth: CGFloat = 320
    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .bold)

    /// The name's own width, up to `nameWidth`.
    private var width: CGFloat {
        let measured = (title.isEmpty ? "Meeting" : title as NSString)
            .size(withAttributes: [.font: Self.nameFont]).width
        return min(Self.nameWidth, ceil(measured) + 4)
    }

    private var when: String {
        subtitle.range(of: " · ").map { String(subtitle[..<$0.lowerBound]) } ?? subtitle
    }

    private var detail: String? {
        subtitle.range(of: " · ").map { String(subtitle[$0.upperBound...]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Ink, whatever the toolbar would make of it.
            Group {
                if isEditable {
                    TextField("Meeting", text: $title)
                        .textFieldStyle(.plain)
                        .frame(width: width)
                } else {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.nameWidth, alignment: .leading)
                }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.primary)
            Text(when)
                .lineLimit(1)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // How long, and who: a line of their own, when there is either.
            if detail != nil || !(attendees ?? []).isEmpty {
                DocumentSubtitle(subtitle: detail, attendees: attendees)
                    .font(.system(size: 11))
            }
        }
        // Its whole width, or the toolbar clips the date; in from the
        // sidebar's edge by the margin the window's own title kept.
        .fixedSize()
        .padding(.leading, 12)
    }
}

/// The line under a document's name: when, and — as a dropdown of its own —
/// who was invited. In the toolbar under the title, and on an event's page
/// above its button. Secondary, at whatever size it is given.
struct DocumentSubtitle: View {
    /// Nil where there is only who was invited to show.
    let subtitle: String?
    /// Nil leaves the chevron out — a dictation has no one invited.
    var attendees: [MeetingAttendee]?
    var chevronSize: CGFloat = 8

    var body: some View {
        HStack(spacing: 5) {
            if let subtitle {
                Text(subtitle)
                    .lineLimit(1)
            }
            if let attendees, !attendees.isEmpty {
                if subtitle != nil { Text("·") }
                Menu {
                    AttendeesMenu(attendees: attendees)
                } label: {
                    HStack(spacing: 3) {
                        Text(attendees.count == 1 ? "1 participant" : "\(attendees.count) participants")
                        Chevron(size: chevronSize)
                    }
                    .contentShape(Rectangle())
                }
                // The plain button under a button-style menu keeps the
                // label as written; borderless redrew it larger, with a
                // chevron of its own in front.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Who was invited; click a name to copy their email")
                .accessibilityLabel("Participants")
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// The title's place in the toolbar: leading, and on bare toolbar — macOS 26
/// would otherwise put the name on a glass capsule of its own.
struct TitleItem<Content: View>: ToolbarContent {
    @ViewBuilder var content: Content

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { content }
        }
    }
}
