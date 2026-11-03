import SwiftUI
import ClioCore

/// A document's name and date, where the window's title would be: the
/// name edited in place, a chevron after it for who was invited, the date
/// under both. Drawn by hand because the window's own title cannot take
/// a menu when it is bridged from a hosting view — `toolbarTitleMenu`
/// showed nothing.
struct DocumentTitle: View {
    @Binding var title: String
    var isEditable = true
    let subtitle: String
    /// Nil leaves the chevron out — a dictation has no one invited.
    var attendees: [MeetingAttendee]?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
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
                if let attendees {
                    Menu {
                        AttendeesMenu(attendees: attendees)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Who was invited")
                    .accessibilityLabel("Attendees")
                }
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Its whole width, or the toolbar clips the date.
        .fixedSize()
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
