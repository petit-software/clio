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
        // A toolbar holding the sidebar button (Clio's glyph, in the place
        // the system's had), the document's name and date at the page's
        // leading edge, and the ⋯ at its trailing one. Every other control
        // is along the sidebar's foot or a document's. Drawn by hand as an
        // overlay, the sidebar button sat wrong and looked it; as a toolbar
        // item it sits where the system's did.
        let toolbar = NSToolbar(identifier: "ClioLibrary")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // No backdrop of its own: the band AppKit draws has a hard edge and
        // one style. Each page draws a fade under the toolbar instead
        // (`pageTopFade`).
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: LibraryView(coordinator: coordinator))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setFrameAutosaveName("ClioLibraryWindow")
        if !window.setFrameUsingName("ClioLibraryWindow") { window.center() }
        #if DEBUG
        // CLIO_LIBRARY_HEIGHT: a short window, whatever was saved, to see
        // the sidebar scroll under its foot. CLIO_LIBRARY_WIDTH: a wide or
        // narrow one, to see the page's margins change.
        let environment = ProcessInfo.processInfo.environment
        let height = environment["CLIO_LIBRARY_HEIGHT"].flatMap(Double.init)
        let width = environment["CLIO_LIBRARY_WIDTH"].flatMap(Double.init)
        if height != nil || width != nil {
            window.setContentSize(NSSize(width: max(600, width ?? 920), height: max(440, height ?? 700)))
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
    @State private var dayEvents: [MeetingEvent] = []
    /// Whether the sidebar shows. The button for it is Clio's own, in the
    /// toolbar where the system's was: SwiftUI hosts the system's as a view
    /// of its own, so its glyph cannot be swapped.
    @State private var columns: NavigationSplitViewVisibility = .all

    private var library: MeetingLibrary? { coordinator.library }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    // Over the sidebar, at its trailing edge, as the system's;
                    // with the sidebar hidden SwiftUI moves it beside the
                    // traffic lights itself.
                    if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                    ToolbarItem(placement: .automatic) { sidebarButton }
                }
                // Last, on the column itself: inside the toolbar modifiers
                // it was not read, and the sidebar opened at 209.
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            detail
        }
        // The system's own field, glass, at the head of the sidebar — with
        // ⌘F, Escape to clear and the sidebar's inset handled for it.
        .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
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

    private var sidebarButton: some View {
        let hidden = columns == .detailOnly
        return Button {
            withAnimation { columns = hidden ? .all : .detailOnly }
        } label: {
            // The chevrons' grey, as Copy is.
            Glyph(icon: .sidebar, size: 20)
                .foregroundStyle(Chevron.colour)
        }
        // The system's button took no focus ring; nor does this one, which
        // is otherwise the first thing in the window to take focus.
        .focusEffectDisabled()
        .help(hidden ? "Show Sidebar" : "Hide Sidebar")
        .accessibilityLabel(hidden ? "Show Sidebar" : "Hide Sidebar")
    }

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
        // Rows fade under the foot's blur and the search field; the system
        // scroll bar through both read as a third control. `scrollIndicators`
        // does nothing to a List on macOS; this swaps the scroller.
        .thinScrollers()
        // The same surface as the page: the sidebar material is covered by
        // the window's background colour, so the two halves are one sheet.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
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
                    // The same disc as Copy across the split, filled with ink:
                    // a record button, the one thing here that starts something.
                    Image(systemName: "circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        // The window's colour on the ink, so it shows in either appearance.
                        // Not `.background`: inside a tinted button that is the tint.
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 22, height: 22)
                }
                    .accessibilityLabel("Take Notes")
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .glassButton(prominent: true, tint: .primary)
                    .help(liveMeeting == nil ? "Take notes for the meeting on now" : "Show the meeting")
                Spacer(minLength: 0)
                // Three buttons on one piece of glass, nothing drawn
                // between them. Each arrow is clickable over the whole
                // height of the glass and out to its end, not just the
                // few points of the glyph.
                HStack(spacing: 0) {
                    Button { move(-1) } label: { dayArrow(.chevronBack) }
                        .accessibilityLabel("Previous Day")
                        .help("Previous day (⌘[)")
                        .keyboardShortcut("[", modifiers: .command)
                    Button(dayTitle) { coordinator.libraryDay = Self.today }
                        .help(isToday ? "Today" : "Back to today")
                        .font(.system(size: 13, weight: .medium))
                        // Ink, not the borderless button's grey.
                        .foregroundStyle(Color.primary)
                        // Wide enough for "Yesterday", so the control keeps
                        // its width whatever day it shows.
                        .frame(width: 72)
                    Button { move(1) } label: { dayArrow(.chevronForward) }
                        .accessibilityLabel("Next Day")
                        .help("Next day (⌘])")
                        .keyboardShortcut("]", modifiers: .command)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.large)
                .fixedSize()
                // The arrows' frames are the capsule's padding now.
                .padding(.horizontal, -14)
                .footCapsule()
            }
            // The same insets as a document's bar, so the two line up
            // across the split.
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            // What scrolls under the foot fades into the sidebar before it
            // reaches the controls.
            .background {
                EdgeFade(edge: .bottom)
                    .padding(.top, -28)
            }
        }
        // The day's events, read again when the day or the calendar changes.
        .task(id: DayKey(day: coordinator.libraryDay, revision: coordinator.calendar.revision)) {
            dayEvents = coordinator.dayEvents(on: coordinator.libraryDay)
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

    /// A day arrow in a frame the height of the glass, wide enough to
    /// reach its rounded end; the glyph sits where the capsule's padding
    /// put it before.
    private func dayArrow(_ icon: LibraryIcon) -> some View {
        Chevron(icon: icon)
            .frame(width: 32, height: 35)
            .contentShape(Rectangle())
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

        // An empty day shows no Calendar section at all; the section is
        // there to offer access when there is none.
        if coordinator.libraryCalendarAccess != .granted || !agenda.events.isEmpty {
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
        }

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
                    // A wash of the ink, lighter than the system's grey
                    // selection, and the same weight in either appearance.
                    .fill(selected ? Color.primary.opacity(0.06) : .clear))
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
                MeetingDocumentView(url: url, library: library, coordinator: coordinator,
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
                Glyph(icon: .calendar, size: 48)
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
            RowIcon(icon: .calendar)
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
    let icon: LibraryIcon
    var color: Color = .secondary

    var body: some View {
        Glyph(icon: icon, size: 16)
            .foregroundStyle(color)
            .frame(width: 18)
            // On the title's line, centred on its capitals as a symbol
            // would be: a shape's baseline is otherwise its bottom edge.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
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
            RowIcon(icon: .calendar,
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
        // The page is the one button, in the middle, the size of the
        // onboarding card's: no link — the address is under the ⋯. Its
        // name and time sit over it, and not in the toolbar.
        Group {
            if !isOver {
                VStack(spacing: 0) {
                    Text(event.title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    DocumentSubtitle(subtitle: Self.when(event), attendees: event.attendees,
                                     chevronSize: 9)
                        .font(.system(size: 13))
                        .padding(.top, 6)
                    joinButton
                        .padding(.top, 24)
                }
                .padding(.horizontal, 28)
            } else {
                Text("No notes were taken for this meeting.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(event.title)
        .toolbar {
            if isOver {
                TitleItem {
                    DocumentTitle(title: .constant(event.title), isEditable: false,
                                  subtitle: Self.when(event), attendees: event.attendees)
                }
            }
            if let url = event.joinURL {
                TrailingToolbarActions {
                    MoreMenu {
                        Button("Copy Meeting URL", systemImage: "link") {
                            TextInjector.copy(url.absoluteString)
                        }
                    }
                }
            }
        }
    }

    /// One button: joining the call when there is one to join, just the
    /// notes when there is not (a meeting in a room).
    private var joinButton: some View {
        Button {
            coordinator.startMeeting(event: event, join: event.joinURL != nil)
        } label: {
            Label(event.joinURL != nil ? "Join & Take Notes" : "Take Notes",
                  systemImage: event.joinURL != nil ? "video.fill" : "record.circle")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(minHeight: 34)
        }
        .inkButton()
        .buttonBorderShape(.capsule)
        // The page's only control: it would take the window's
        // focus ring just for being there.
        .focusEffectDisabled()
    }

    static func when(_ event: MeetingEvent) -> String {
        whenLine(start: event.start, end: event.end)
    }
}

private struct DictationRow: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RowIcon(icon: .transcript)
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
    /// For the summary: which model writes it, and whether it is being
    /// written for this file now.
    let coordinator: AppCoordinator
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

    init(url: URL, library: MeetingLibrary, coordinator: AppCoordinator,
         selection: Binding<LibrarySelection?>) {
        self.library = library
        self.coordinator = coordinator
        _selection = selection
        _url = State(initialValue: url)
    }

    private var isSummarizing: Bool { coordinator.isSummarizing(url) }

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
        // A new summary landed in the file: take it, and only it — the
        // notes here may be newer than the file's.
        .onChange(of: isSummarizing) { was, now in
            guard was, !now, let fresh = library.record(at: url)?.summary else { return }
            record?.summary = fresh
            if isDirty { flush() }
            pane = .summary
        }
        .confirmationDialog("Move “\(record?.title ?? "this meeting")” to the Trash?",
                            isPresented: $confirmingTrash) {
            Button("Move to Trash", role: .destructive) {
                save?.cancel()
                isDirty = false
                coordinator.cancelSummary(url)
                try? library.trash(url)
                selection = nil
            }
        } message: {
            Text("Its notes, summary and transcript go with it. Finder can put it back.")
        }
    }

    private func load() {
        record = library.record(at: url)
        if record?.summary == nil, !isSummarizing { pane = .notes }
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
                    if isSummarizing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Writing the summary with \(coordinator.summaryModelName)…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                    } else if let problem = coordinator.summaryProblem, record.summary == nil {
                        Text(problem)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 12)
                    }
                    MarkdownEditor(text: .constant(record.titledSummary ?? ""), isEditable: false,
                                   minHeight: 0)
                        .padding(.horizontal, 8)
                case .transcript:
                    TranscriptList(lines: record.lines, isLive: false)
                }
            }
            .padding(.bottom, 80)
            .pageMargins()
        }
        .nativeTopEdge()
        .pageTopFade()
        .thinScrollers()
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
                    // Each part on its own; the foot's Copy takes the pane showing.
                    Button("Copy Notes", systemImage: "note.text") { TextInjector.copy(record.notes) }
                        .disabled(record.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Copy Summary", systemImage: "text.badge.star") {
                        TextInjector.copy(record.titledSummary ?? "")
                    }
                    .disabled(record.summary == nil)
                    Button("Copy Transcript", systemImage: "text.quote") {
                        TextInjector.copy(record.transcriptText)
                    }
                    .disabled(record.lines.isEmpty)
                    Button("Copy Meeting as Markdown", systemImage: "doc.plaintext") {
                        TextInjector.copy(MeetingMarkdown.render(record))
                    }
                    if let link = record.joinURL {
                        Button("Copy Meeting URL", systemImage: "link") {
                            TextInjector.copy(link.absoluteString)
                        }
                    }
                    Divider()
                    // With the model Settings ▸ Model names now — so a
                    // meeting summarised by Apple's model can be done again
                    // by a downloaded one, or after the notes were edited.
                    Button(record.summary == nil ? "Write Summary" : "Summarize Again",
                           systemImage: "text.badge.star") {
                        flush()
                        coordinator.resummarize(url)
                        pane = .summary
                    }
                    .disabled(record.lines.isEmpty || isSummarizing || !coordinator.canSummarize)
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
                PaneMenu(panes: panes(record), pane: $pane)
            } trailing: {
                CopyButton(help: pane.copyHelp) { TextInjector.copy(pane.text(of: record)) }
            }
        }
    }

    private func panes(_ record: MeetingRecord) -> [MeetingView.Pane] {
        record.summary == nil && !isSummarizing ? [.notes, .transcript] : [.summary, .notes, .transcript]
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
                .pageMargins()
        }
        .nativeTopEdge()
        .pageTopFade()
        .thinScrollers()
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
