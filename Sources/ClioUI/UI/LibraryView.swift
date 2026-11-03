import AppKit
import SwiftUI
import ClioCore

/// What the library window is showing.
public enum LibrarySelection: Hashable, Sendable {
    /// The meeting being recorded now.
    case live
    case meeting(URL)
    case dictation(UUID)
    /// A calendar event with no notes yet.
    case event(String)
}

/// Clio's one real window: every meeting and dictation down the side, the
/// one picked as a document on the right.
///
/// Clio is a menu bar app, so it has no Dock icon — until this is open. A
/// window people work in should be in ⌘-Tab and the Dock while it is up,
/// and gone from both when it closes.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(coordinator: AppCoordinator) {
        NSApp.setActivationPolicy(.regular)
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Clio"
        // The name is drawn by the document itself (`DocumentTitle`), so
        // its chevron can sit right after it; the window's own stays for
        // the Window menu and Mission Control.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 440)
        // A toolbar holding the split view's own sidebar button, drawn by
        // the system beside the traffic lights, the document's name and
        // date at the page's leading edge, and the pane picker at its
        // trailing one. Every other control is along the sidebar's foot
        // or a document's. Drawn by hand as an overlay, the sidebar button
        // sat wrong and looked it.
        let toolbar = NSToolbar(identifier: "ClioLibrary")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        let host = NSHostingView(rootView: LibraryView(coordinator: coordinator))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setFrameAutosaveName("ClioLibraryWindow")
        if !window.setFrameUsingName("ClioLibraryWindow") { window.center() }
        #if DEBUG
        // CLIO_LIBRARY_HEIGHT: a short window, whatever was saved, to see
        // the sidebar scroll under its foot.
        if let set = ProcessInfo.processInfo.environment["CLIO_LIBRARY_HEIGHT"].flatMap(Double.init) {
            window.setContentSize(NSSize(width: 920, height: max(440, set)))
            window.center()
        }
        #endif
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app. Settings may still be open; it keeps its
        // own place without a Dock icon, as it always has.
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }
}

struct LibraryView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var dayEvents: [MeetingEvent] = []
    /// Whether the sidebar shows. The system's button for it lived in the
    /// toolbar, which is gone; ours is in the sidebar's foot, and beside
    /// the traffic lights while the sidebar is hidden.
    @State private var columns: NavigationSplitViewVisibility = .all

    private var library: MeetingLibrary? { coordinator.library }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            detail
        }
        // A meeting that has just finished is a file now; follow it there.
        .onChange(of: coordinator.meeting?.phase) { _, phase in
            guard phase == .finished else { return }
            library?.reload()
            if coordinator.librarySelection == .live, let url = coordinator.meeting?.fileURL {
                coordinator.librarySelection = .meeting(url)
            }
        }
    }

    // MARK: Sidebar

    private var liveMeeting: MeetingSession? {
        guard let meeting = coordinator.meeting, meeting.phase != .finished else { return nil }
        return meeting
    }

    private var sidebar: some View {
        // No `selection:` — the list would draw its own, in the accent
        // colour, whatever tint it is given. Each row draws a light one
        // instead (`selectable`), and ↑/↓ are handled below.
        List {
            if query.isEmpty {
                daySections
            } else {
                searchSections
            }
        }
        .listStyle(.sidebar)
        // Search at the head of the sidebar, flat: the system's own field
        // is glass, and glass is for what floats over the page.
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .overlay {
            if !query.isEmpty, library?.hasLoaded == true, groups.isEmpty, dictations.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        // The foot of the sidebar: Take Notes and the day it shows.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { coordinator.startMeeting() } label: {
                    // The same disc as Copy across the split.
                    Image(systemName: "record.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                    .accessibilityLabel("Take Notes")
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .glassButton()
                    .help(liveMeeting == nil ? "Take notes for the meeting on now" : "Show the meeting")
                Spacer(minLength: 0)
                // Three buttons on one piece of glass, nothing drawn
                // between them.
                HStack(spacing: 8) {
                    Button("Previous Day", systemImage: "chevron.compact.backward") { move(-1) }
                        .help("Previous day (⌘[)")
                        .keyboardShortcut("[", modifiers: .command)
                        .fontWeight(.bold)
                    Button(dayTitle) { coordinator.libraryDay = Self.today }
                        .help(isToday ? "Today" : "Back to today")
                        .font(.system(size: 13, weight: .medium))
                        // Ink, not the borderless button's grey.
                        .foregroundStyle(Color.primary)
                        // Wide enough for "Yesterday", so the control keeps
                        // its width whatever day it shows.
                        .frame(width: 72)
                    Button("Next Day", systemImage: "chevron.compact.forward") { move(1) }
                        .help("Next day (⌘])")
                        .keyboardShortcut("]", modifiers: .command)
                        .fontWeight(.bold)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.large)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .glassSurface(Capsule())
                .fixedSize()
            }
            // The same insets as a document's bar, so the two line up
            // across the split.
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            // What scrolls under the foot fades into frost before it
            // reaches the controls.
            .background {
                Rectangle()
                    .fill(.regularMaterial)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black, location: 0.5)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .padding(.top, -28)
            }
        }
        // The day's events, read again when the day or the calendar changes.
        .task(id: DayKey(day: coordinator.libraryDay, revision: coordinator.calendar.revision)) {
            dayEvents = coordinator.dayEvents(on: coordinator.libraryDay)
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // Rows scrolling up fade into frost before they reach the field,
        // as they do at the foot.
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.5),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .padding(.bottom, -24)
        }
        // ⌘F finds, as the system field's did.
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    // MARK: The day

    private struct DayKey: Equatable {
        var day: Date
        var revision: Int
    }

    private static var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var isToday: Bool { Calendar.current.isDateInToday(coordinator.libraryDay) }

    private var dayTitle: String {
        let day = coordinator.libraryDay
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.day().month(.abbreviated))
    }

    private func move(_ days: Int) {
        coordinator.libraryDay = DayAgenda.step(coordinator.libraryDay, by: days)
    }

    private var agenda: DayAgenda {
        DayAgenda.make(day: coordinator.libraryDay, events: dayEvents,
                       files: (library?.files ?? []).filter { $0.url != liveMeeting?.fileURL },
                       dictations: coordinator.libraryDictations)
    }

    /// A section's title, 12pt in from the edge.
    private func header(_ title: String) -> some View {
        Text(title).padding(.leading, 12)
    }

    @ViewBuilder
    private var daySections: some View {
        let agenda = agenda
        if let meeting = liveMeeting, isToday {
            Section { selectable(.live) { LiveRow(meeting: meeting) } } header: { header("Now") }
        }

        Section {
            switch coordinator.libraryCalendarAccess {
            case .notDetermined:
                Button("Show your calendar") {
                    Task { await coordinator.calendar.requestAccess() }
                }
                .buttonStyle(.link)
            case .denied:
                Button("Calendar access is off — open Privacy Settings") {
                    coordinator.calendar.openPrivacySettings()
                }
                .buttonStyle(.link)
            case .granted:
                if agenda.events.isEmpty {
                    Text("Nothing on the calendar")
                        .foregroundStyle(.secondary)
                }
                ForEach(agenda.events) { item in
                    selectable(eventSelection(item)) {
                        EventRow(item: item, isToday: isToday) {
                            coordinator.join(item.event)
                        }
                    }
                    .contextMenu {
                        if let notes = item.notes { meetingMenu(notes.url) }
                    }
                }
            }
        } header: { header("Calendar") }

        if !agenda.otherNotes.isEmpty {
            Section {
                ForEach(agenda.otherNotes) { file in
                    selectable(.meeting(file.url)) { MeetingRow(file: file) }
                        .contextMenu { meetingMenu(file.url) }
                }
            } header: { header("Notes") }
        }

        if !agenda.dictations.isEmpty {
            Section {
                ForEach(agenda.dictations) { entry in
                    dictationRow(entry)
                }
            } header: { header("Dictations") }
        }
    }

    /// An event opens its notes if it has any, its details if not.
    private func eventSelection(_ item: DayAgenda.Event) -> LibrarySelection {
        item.notes.map { .meeting($0.url) } ?? .event(item.event.id)
    }

    // MARK: Search

    /// Every day's meetings and dictations matching the search.
    @ViewBuilder
    private var searchSections: some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.files) { file in
                    selectable(.meeting(file.url)) { MeetingRow(file: file) }
                        .contextMenu { meetingMenu(file.url) }
                }
            } header: { header(group.title) }
        }
        if !dictations.isEmpty {
            Section {
                ForEach(dictations) { entry in
                    dictationRow(entry)
                }
            } header: { header("Dictations") }
        }
    }

    private func dictationRow(_ entry: TranscriptEntry) -> some View {
        selectable(.dictation(entry.id)) { DictationRow(entry: entry) }
            .contextMenu {
                Button("Copy", systemImage: "square.fill.on.square.fill") {
                    TextInjector.copy(entry.text)
                }
                Button("Remove", systemImage: "minus.circle.fill", role: .destructive) {
                    coordinator.removeDictation(id: entry.id)
                }
            }
    }

    /// A row that selects itself on a click, with a light highlight when it
    /// is the one showing — not the accent: the sidebar is for finding a
    /// note, and the note is what should stand out.
    private func selectable<Row: View>(_ tag: LibrarySelection,
                                       @ViewBuilder row: () -> Row) -> some View {
        let selected = coordinator.librarySelection == tag
        return row()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                                   : .clear))
            .contentShape(Rectangle())
            .onTapGesture { coordinator.librarySelection = tag }
            // The highlight reaches the list's edges; the text lines up
            // under the section headings.
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Everything selectable, top to bottom, for ↑ and ↓.
    private var order: [LibrarySelection] {
        guard query.isEmpty else {
            return groups.flatMap { $0.files.map { .meeting($0.url) } }
                + dictations.map { .dictation($0.id) }
        }
        let agenda = agenda
        return (liveMeeting != nil && isToday ? [.live] : [])
            + agenda.events.map(eventSelection)
            + agenda.otherNotes.map { .meeting($0.url) }
            + agenda.dictations.map { .dictation($0.id) }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let order = order
        guard !order.isEmpty else { return .ignored }
        let current = coordinator.librarySelection.flatMap { order.firstIndex(of: $0) }
        let next = current.map { min(max($0 + by, 0), order.count - 1) } ?? 0
        coordinator.librarySelection = order[next]
        return .handled
    }

    private var groups: [MeetingLibrary.Group] {
        guard let library else { return [] }
        let live = liveMeeting?.fileURL
        let files = library.search(query).filter { $0.url != live }
        return MeetingLibrary.groups(files)
    }

    private var dictations: [TranscriptEntry] {
        let all = coordinator.libraryDictations
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.filter { entry in words.allSatisfy { entry.text.lowercased().contains($0) } }
    }

    @ViewBuilder
    private func meetingMenu(_ url: URL) -> some View {
        Button("Show in Finder", systemImage: "folder.fill") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Open in Default App", systemImage: "doc.text") { NSWorkspace.shared.open(url) }
        Divider()
        Button("Move to Trash", systemImage: "minus.circle.fill", role: .destructive) {
            try? library?.trash(url)
            if coordinator.librarySelection == .meeting(url) { coordinator.librarySelection = nil }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch coordinator.librarySelection {
        case .live:
            if let meeting = coordinator.meeting {
                MeetingView(meeting: meeting, coordinator: coordinator)
            } else {
                nothingSelected
            }
        case .meeting(let url):
            if let library {
                MeetingDocumentView(url: url, library: library,
                                    selection: $coordinator.librarySelection)
                    .id(url)
            }
        case .dictation(let id):
            if let entry = coordinator.libraryDictations.first(where: { $0.id == id }) {
                DictationView(entry: entry) {
                    coordinator.removeDictation(id: id)
                }
            } else {
                nothingSelected
            }
        case .event(let id):
            if let event = dayEvents.first(where: { $0.id == id }) {
                EventView(event: event, coordinator: coordinator)
            } else {
                nothingSelected
            }
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView {
            Label {
                Text("Pick a meeting\nor a dictation on the left.")
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: "calendar.day")
            }
        }
        .navigationTitle("Clio")
    }
}

// MARK: - Rows

private struct LiveRow: View {
    @Bindable var meeting: MeetingSession

    var body: some View {
        HStack(spacing: 8) {
            // In the icons' column, so the titles line up.
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(meeting.isActive
                         ? "Recording · \(MeetingLine.timestamp(meeting.elapsed))"
                         : "Finishing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MeetingRow: View {
    let file: MeetingFile

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RowIcon(symbol: "calendar.day")
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(file.start, style: .time)
                    if !file.preview.isEmpty {
                        Text("·")
                        Text(file.preview).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// What a row is, at a glance: a meeting, or a dictation. Fixed width, so
/// the titles line up whatever the symbol.
private struct RowIcon: View {
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

/// A calendar event in the day: when, what, and whether there are notes —
/// or, for one about to start with a link, a way to join.
private struct EventRow: View {
    let item: DayAgenda.Event
    let isToday: Bool
    let join: () -> Void

    private var event: MeetingEvent { item.event }
    /// While the call is on and there is one to join — notes or not, so a
    /// dropped call can be rejoined from here.
    private var canJoin: Bool {
        event.joinURL != nil && isToday && event.end > Date()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The meeting icon, in the colour of the calendar it is on.
            // Here only; the page is not coloured.
            RowIcon(symbol: "calendar.day",
                    color: event.calendarColor.map {
                        Color(red: $0.red, green: $0.green, blue: $0.blue)
                    } ?? .secondary)
            // The same shape as a meeting that happened: the title, then
            // the time under it, with what there is to say about it.
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.start, style: .time)
                    if item.notes != nil {
                        Text("·")
                        Text("Notes")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if canJoin {
                // Quiet beside the event: a plain grey capsule — no glass,
                // which in a list of rows read as one more surface.
                Button("Join", action: join)
                    .buttonStyle(GreyCapsuleButtonStyle())
                    .help(item.notes == nil ? "Join the call and take notes" : "Join the call")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A calendar event with no notes: what it is, who is in it, and — while it
/// is still to come — taking notes for it.
private struct EventView: View {
    let event: MeetingEvent
    let coordinator: AppCoordinator

    private var isOver: Bool { event.end < Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let url = event.joinURL {
                    Link(url.host ?? url.absoluteString, destination: url)
                        .font(.system(size: 12))
                        // Not the first responder's ring: the page is
                        // opened by a click in the sidebar, not by Tab.
                        .focusEffectDisabled()
                }
                if !isOver {
                    // One button: joining the call when there is one to join,
                    // just the notes when there is not (a meeting in a room).
                    Group {
                        if event.joinURL != nil {
                            Button("Join & Take Notes", systemImage: "video.fill") {
                                coordinator.startMeeting(event: event, join: true)
                            }
                        } else {
                            Button("Take Notes", systemImage: "record.circle") {
                                coordinator.startMeeting(event: event)
                            }
                        }
                    }
                    .inkButton()
                    .controlSize(.large)
                    .padding(.top, 14)
                } else {
                    Text("No notes were taken for this meeting.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softTopEdge()
        .navigationTitle(event.title)
        .toolbar {
            TitleItem {
                DocumentTitle(title: .constant(event.title), isEditable: false,
                              subtitle: Self.when(event), attendees: event.attendees)
            }
        }
    }

    static func when(_ event: MeetingEvent) -> String {
        whenLine(start: event.start, end: event.end)
    }
}

private struct DictationRow: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RowIcon(symbol: "text.bubble")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - A saved meeting

/// A meeting from the folder, as a document: its title and notes can be
/// edited, and every edit is written back to the file a moment later.
struct MeetingDocumentView: View {
    let library: MeetingLibrary
    @Binding var selection: LibrarySelection?

    @State private var url: URL
    @State private var record: MeetingRecord?
    @State private var pane: MeetingView.Pane = .summary
    @State private var save: Task<Void, Never>?
    @State private var confirmingTrash = false
    /// Whether anything was edited since the last save. Only then is the
    /// file written: viewing a meeting must not rewrite it, and leaving one
    /// that was just trashed must not bring it back.
    @State private var isDirty = false

    init(url: URL, library: MeetingLibrary, selection: Binding<LibrarySelection?>) {
        self.library = library
        _selection = selection
        _url = State(initialValue: url)
    }

    var body: some View {
        Group {
            if let record {
                document(record)
            } else {
                ContentUnavailableView("This meeting could not be read", systemImage: "doc.questionmark",
                                       description: Text(url.lastPathComponent))
            }
        }
        .onAppear(perform: load)
        // Leaving the document saves what is pending at once.
        .onDisappear { flush() }
        .confirmationDialog("Move “\(record?.title ?? "this meeting")” to the Trash?",
                            isPresented: $confirmingTrash) {
            Button("Move to Trash", role: .destructive) {
                save?.cancel()
                isDirty = false
                try? library.trash(url)
                selection = nil
            }
        } message: {
            Text("Its notes, summary and transcript go with it. Finder can put it back.")
        }
    }

    private func load() {
        record = library.record(at: url)
        if record?.summary == nil { pane = .notes }
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["CLIO_MEETING_PANE"],
           let chosen = MeetingView.Pane.allCases.first(where: { $0.rawValue.lowercased() == name }) {
            pane = chosen
        }
        #endif
    }

    /// The meeting as one page that scrolls under the window's glass
    /// toolbar, which carries its title (edited there) and its date; the
    /// pane is picked bottom left.
    private func document(_ record: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 12)

                switch pane {
                case .notes:
                    MarkdownEditor(text: binding(\.notes), placeholder: "Notes, in Markdown.",
                                   minHeight: 320)
                        .padding(.horizontal, 8)
                case .summary:
                    MarkdownEditor(text: .constant(record.summary ?? ""), isEditable: false,
                                   minHeight: 0)
                        .padding(.horizontal, 8)
                case .transcript:
                    TranscriptList(lines: record.lines, isLive: false)
                }
            }
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softTopEdge()
        .navigationTitle(record.title)
        .toolbar {
            TitleItem {
                DocumentTitle(title: binding(\.title), subtitle: Self.when(record),
                              attendees: record.attendees)
            }
            // Everything else about the file, top right.
            TrailingToolbarActions {
                MoreMenu {
                    Button("Show in Finder", systemImage: "folder.fill") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Open in Default App", systemImage: "doc.text") {
                        NSWorkspace.shared.open(url)
                    }
                    Button("Copy Transcript", systemImage: "text.quote") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.transcriptText, forType: .string)
                    }
                    .disabled(record.lines.isEmpty)
                    Divider()
                    Button("Move to Trash", systemImage: "minus.circle.fill", role: .destructive) {
                        confirmingTrash = true
                    }
                }
            }
        }
        #if DEBUG
        // For the tools: open scrolled to the end, so the toolbar has the
        // document passing under it to be judged against.
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["CLIO_LIBRARY_SCROLLED"] != nil
                             ? .bottom : nil)
        #endif
        // What it shows, and what to do with it, along its foot.
        .overlay(alignment: .bottom) {
            DocumentBar {
                Picker("Show", selection: $pane) {
                    ForEach(panes(record)) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            } trailing: {
                CopyButton(help: "Copy the whole meeting as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingMarkdown.render(record), forType: .string)
                }
            }
        }
    }

    private func panes(_ record: MeetingRecord) -> [MeetingView.Pane] {
        record.summary == nil ? [.notes, .transcript] : [.summary, .notes, .transcript]
    }

    /// An editable field of the record that saves itself a beat after typing.
    private func binding(_ keyPath: WritableKeyPath<MeetingRecord, String>) -> Binding<String> {
        Binding(
            get: { record?[keyPath: keyPath] ?? "" },
            set: { value in
                guard record?[keyPath: keyPath] != value else { return }
                record?[keyPath: keyPath] = value
                isDirty = true
                save?.cancel()
                save = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    flush()
                }
            })
    }

    private func flush() {
        save?.cancel()
        save = nil
        // Not edited, or gone — trashed from the sidebar while open, or
        // deleted in Finder: nothing to write, and nothing to bring back.
        guard isDirty, var record,
              FileManager.default.fileExists(atPath: url.path) else { return }
        isDirty = false
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.title = title.isEmpty ? "Meeting" : title
        guard let written = try? library.save(record, at: url), written != url else { return }
        // A new title is a new file name; keep the sidebar pointing at it.
        url = written
        selection = .meeting(written)
    }

    static func when(_ record: MeetingRecord) -> String {
        whenLine(start: record.startDate, end: record.endDate)
    }
}

/// "Tuesday, 3 November 2026 at 09:25 · 32 min" — the one date line, for a
/// meeting that happened and one still to come alike.
func whenLine(start: Date, end: Date?) -> String {
    let day = DateFormatter()
    day.dateStyle = .full
    day.timeStyle = .short
    var text = day.string(from: start)
    if let end {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        text += " · \(minutes < 1 ? "under a minute" : "\(minutes) min")"
    }
    return text
}

// MARK: - A dictation

private struct DictationView: View {
    let entry: TranscriptEntry
    let remove: () -> Void

    var body: some View {
        ScrollView {
            MarkdownEditor(text: .constant(entry.text), isEditable: false, minHeight: 0)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
        }
        .softTopEdge()
        .navigationTitle("Dictation")
        .toolbar {
            TitleItem {
                DocumentTitle(title: .constant("Dictation"), isEditable: false,
                              subtitle: entry.date.formatted(date: .complete, time: .shortened))
            }
            TrailingToolbarActions {
                MoreMenu {
                    Button("Remove", systemImage: "minus.circle.fill", role: .destructive, action: remove)
                }
            }
        }
        .overlay(alignment: .bottom) {
            DocumentBar {
                EmptyView()
            } trailing: {
                CopyButton(help: "Copy the dictation") { TextInjector.copy(entry.text) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Shared

/// What was said, in turns. No scroll of its own: it is part of the
/// document's one scroll, under the toolbar.
struct TranscriptList: View {
    let lines: [MeetingLine]
    let isLive: Bool

    var body: some View {
        let paragraphs = MeetingMarkdown.paragraphs(lines)
        LazyVStack(alignment: .leading, spacing: 12) {
            if paragraphs.isEmpty {
                Text(isLive ? "Listening. Lines appear a few seconds after they are said."
                            : "Nothing was transcribed.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(paragraphs) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(line.speaker.label) · \(line.timestamp)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(line.speaker == .me ? Color.accentColor : .secondary)
                    Text(line.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(line.id)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A flat grey capsule: the label in the text colour on a light fill that
/// darkens a little when pressed.
private struct GreyCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}
