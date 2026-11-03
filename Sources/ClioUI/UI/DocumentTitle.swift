import SwiftUI
import ClioCore

/// A document's name and date, where the window's title would be: the
/// name edited in place; under it the date and, as a dropdown of its own,
/// who was invited. Drawn by hand because the window's own title cannot
/// take a menu when it is bridged from a hosting view — `toolbarTitleMenu`
/// showed nothing.
struct DocumentTitle: View {
    @Binding var title: String
    var isEditable = true
    let subtitle: String
    /// Nil leaves the chevron out — a dictation has no one invited.
    var attendees: [MeetingAttendee]?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isEditable {
                TextField("Meeting", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .fixedSize()
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Text(subtitle)
                    .lineLimit(1)
                if let attendees, !attendees.isEmpty {
                    Text("·")
                    Menu {
                        AttendeesMenu(attendees: attendees)
                    } label: {
                        HStack(spacing: 3) {
                            Text(attendees.count == 1 ? "1 participant" : "\(attendees.count) participants")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
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
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        // Its whole width, or the toolbar clips the date; in from the
        // sidebar's edge by the margin the window's own title kept.
        .fixedSize()
        .padding(.leading, 12)
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
