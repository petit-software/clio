import SwiftUI
import ClioCore

/// Search, as a palette over the library window: one field, and under it
/// what matches — a few things to do, every meeting whose title, people,
/// notes, summary or transcript has each word, and the dictations that do.
/// ⌘F or the magnifier opens it; ↑ ↓ move, Return opens, Esc or a click
/// outside closes. With nothing typed it offers the actions and the latest
/// meetings, so it is also the quickest way back to one.
///
/// It replaced the sidebar's search field: the sidebar is a day, and a
/// search across every day did not belong at the head of it.
struct CommandPalette: View {
    let coordinator: AppCoordinator
    @Binding var isShown: Bool

    @State private var query = ""
    @State private var highlighted = 0
    /// How tall the list may be: 380, or what the window leaves under the
    /// field — in a short window it ran off the bottom.
    @State private var listHeight: CGFloat = 380
    @FocusState private var fieldFocused: Bool

    /// Something the palette can do with Return.
    struct Item: Identifiable {
        enum Kind { case action, meeting, dictation }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let icon: LibraryIcon?
        let run: () -> Void
    }

    private var words: [String] {
        query.lowercased().split(separator: " ").map(String.init)
    }

    private var actions: [Item] {
        let all: [Item] = [
            Item(id: "action.notes", kind: .action, title: "Take Notes",
                 subtitle: "Start recording a meeting", icon: nil) { [coordinator] in
                coordinator.startMeeting()
            },
            Item(id: "action.today", kind: .action, title: "Go to Today",
                 subtitle: "Today's meetings and dictations", icon: .calendar) { [coordinator] in
                coordinator.libraryDay = Calendar.current.startOfDay(for: Date())
            },
        ]
        guard !words.isEmpty else { return all }
        return all.filter { item in words.allSatisfy { item.title.lowercased().contains($0) } }
    }

    private var meetings: [Item] {
        guard let library = coordinator.library else { return [] }
        let files = library.search(query).sorted { $0.start > $1.start }
        return files.prefix(words.isEmpty ? 6 : 30).map { file in
            Item(id: file.url.absoluteString, kind: .meeting, title: file.title,
                 subtitle: subtitle(file), icon: .calendar) { [coordinator] in
                coordinator.libraryDay = Calendar.current.startOfDay(for: file.start)
                coordinator.librarySelection = .meeting(file.url)
            }
        }
    }

    private var dictations: [Item] {
        guard !words.isEmpty else { return [] }
        return coordinator.libraryDictations
            .filter { entry in words.allSatisfy { entry.text.lowercased().contains($0) } }
            .prefix(15)
            .map { entry in
                Item(id: entry.id.uuidString, kind: .dictation, title: entry.text,
                     subtitle: entry.date.formatted(date: .abbreviated, time: .shortened),
                     icon: .transcript) { [coordinator] in
                    coordinator.libraryDay = Calendar.current.startOfDay(for: entry.date)
                    coordinator.librarySelection = .dictation(entry.id)
                }
            }
    }

    private func subtitle(_ file: MeetingFile) -> String {
        let when = file.start.formatted(date: .abbreviated, time: .shortened)
        return file.preview.isEmpty ? when : "\(when) · \(file.preview)"
    }

    private var sections: [(title: String, items: [Item])] {
        [("Actions", actions),
         (words.isEmpty ? "Recent meetings" : "Meetings", meetings),
         ("Dictations", dictations)]
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        let sections = sections
        let items = sections.flatMap(\.items)
        ZStack(alignment: .top) {
            // A click anywhere else closes it.
            Color.black.opacity(0.06)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                field(items)
                if !items.isEmpty || !words.isEmpty {
                    Divider()
                    results(sections, items)
                }
            }
            .frame(width: 560)
            // Opaque: the window's background colour let the page and the
            // sidebar show faintly through.
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .padding(.top, 72)
            .padding(.horizontal, 20)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // The panel's top inset, the field and its rule, and a margin.
            listHeight = max(120, min(380, height - 72 - 55 - 24))
        }
        .onAppear {
            query = ""
            #if DEBUG
            if let typed = ProcessInfo.processInfo.environment["CLIO_PALETTE_SHOW"], typed != "1" {
                query = typed
            }
            #endif
            highlighted = 0
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func field(_ items: [Item]) -> some View {
        HStack(spacing: 10) {
            Glyph(icon: .search, size: 22)
                .foregroundStyle(Chevron.colour)
            TextField("Search meetings and dictations", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit { open(items) }
                .onKeyPress(.downArrow) { move(1, in: items) }
                .onKeyPress(.upArrow) { move(-1, in: items) }
                .onKeyPress(.escape) { close(); return .handled }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder
    private func results(_ sections: [(title: String, items: [Item])], _ items: [Item]) -> some View {
        if items.isEmpty {
            Text("Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.title) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(section.items) { item in
                                row(item, isHighlighted: items.firstIndex { $0.id == item.id } == highlighted)
                                    .id(item.id)
                                    .onTapGesture { run(item) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                    // The sidebar's scroll bar: a faint thin line, shown
                    // while the pointer is over the list. From inside the
                    // list, so the scroll view it finds first is this one —
                    // from outside it found the page's.
                    .thinScrollers()
                }
                .frame(maxHeight: listHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlighted) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
        }
    }

    private func row(_ item: Item, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let icon = item.icon {
                    Glyph(icon: icon, size: 16)
                } else {
                    // Take Notes: the record dot, as on the sidebar's button.
                    Circle().frame(width: 9, height: 9)
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHighlighted ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
    }

    private func move(_ by: Int, in items: [Item]) -> KeyPress.Result {
        guard !items.isEmpty else { return .handled }
        highlighted = min(max(highlighted + by, 0), items.count - 1)
        return .handled
    }

    private func open(_ items: [Item]) {
        guard items.indices.contains(highlighted) else { return }
        run(items[highlighted])
    }

    private func run(_ item: Item) {
        close()
        item.run()
    }

    private func close() { isShown = false }
}
