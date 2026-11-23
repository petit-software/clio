import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    /// The smallest the window's content goes; the toolbar is on top of it.
    private static let smallest = NSSize(width: 780, height: 440)

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
        // The window's smallest size is the content's, said in SwiftUI: the
        // hosting view sets the window's from what the content needs, and
        // `minSize` set on the window read back as zero a moment later.
        let host = NSHostingView(rootView: LibraryView(coordinator: coordinator)
            .frame(minWidth: Self.smallest.width, minHeight: Self.smallest.height))
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
        // Nothing in the window has the keyboard until Tab is pressed:
        // left to itself the first thing that can take it does — Take
        // Notes, with a focus ring nobody asked for.
        Self.dropFocus()
    }

    /// Takes the keyboard's focus off whatever in the library window has
    /// it, now and once SwiftUI has finished laying the window out. Tab
    /// still starts from the first control.
    static func dropFocus() {
        func drop() {
            guard let window = NSApp.windows.first(where: { $0.title == "Clio" && $0.toolbar != nil })
            else { return }
            // Never from text being written: the notes keep their caret.
            if window.firstResponder is NSTextView { return }
            window.makeFirstResponder(nil)
        }
        drop()
        DispatchQueue.main.async(execute: drop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: drop)
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
    /// The search palette (`CommandPalette`), over the whole window.
    @State private var paletteShown = false
    /// What the palette is picking an event for, when it is not searching.
    @State private var eventPick: EventPick?
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
        // A recording dropped anywhere on the window becomes a meeting.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url,
                      let type = UTType(filenameExtension: url.pathExtension),
                      AppCoordinator.importableTypes.contains(where: type.conforms(to:)) else { return }
                Task { @MainActor in coordinator.importRecording(url) }
            }
            return true
        }
        // Search is the palette, over the window: the magnifier beside each
        // page's ⋯ (`SearchButton`) and ⌘F, from anywhere in the window.
        .environment(\.openSearch) { eventPick = nil; paletteShown = true }
        .environment(\.pickEvent) { eventPick = $0; paletteShown = true }
        .background {
            Button("Search") { eventPick = nil; paletteShown = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .overlay {
            if paletteShown {
                CommandPalette(coordinator: coordinator, isShown: $paletteShown, picking: eventPick)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: paletteShown)
        // A `clio://search` link: the palette, open on what it asked for.
        .onChange(of: coordinator.requestedSearch, initial: true) { _, query in
            if query != nil { eventPick = nil; paletteShown = true }
        }
        #if DEBUG
        // CLIO_PALETTE_SHOW: the palette open on launch, its value typed in.
        .onAppear {
            if ProcessInfo.processInfo.environment["CLIO_PALETTE_SHOW"] != nil { paletteShown = true }
            // CLIO_SIDEBAR_HIDE: the window with its sidebar hidden.
            if ProcessInfo.processInfo.environment["CLIO_SIDEBAR_HIDE"] != nil { columns = .detailOnly }
        }
        #endif
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
            // What had the keyboard may have just gone, and AppKit hands
            // it to the next thing that can take it — Take Notes, ringed,
            // and one press of Space from recording. Nothing has it until
            // Tab is pressed.
            LibraryWindowController.dropFocus()
        } label: {
            // The chevrons' grey, as Copy is.
            Glyph(icon: .sidebar, size: 20)
                .foregroundStyle(ToolbarInk.colour)
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

    @State private var isOverSidebar = false

    private var sidebar: some View {
        // No `selection:` — the list would draw its own, in the accent
        // colour, whatever tint it is given. Each row draws a light one
        // instead (`selectable`), and ↑/↓ are handled below.
        List {
            daySections
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
        // The head of the sidebar: the day it shows, and the way to another.
        .safeAreaInset(edge: .top, spacing: 0) { dayHeader }
        // The foot of the sidebar: Take Notes.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                takeNotesButton
                Spacer(minLength: 0)
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
        .onHover { isOverSidebar = $0 }
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

    /// "18 Nov": the day the sidebar shows, always as a date.
    private var dayTitle: String {
        coordinator.libraryDay.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "Today", "Yesterday" or "Tomorrow", for the days that have a name.
    private var dayName: String? {
        let day = coordinator.libraryDay
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return nil
    }

    /// Over the list: the date — with the day's name above it when it has
    /// one, in a section title's type. The name's line is always there,
    /// empty or not, so the date does not move as the days go by. The
    /// arrows to the days either side are on its line, at the right edge.
    private var dayHeader: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { coordinator.libraryDay = Self.today } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dayName ?? "Today")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(dayName == nil ? 0 : 1)
                    Text(dayTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A click target, not a stop for the keyboard: focused, it drew
            // the window's blue ring round the date.
            .focusable(false)
            .help(isToday ? "Today" : "Back to today")
            .accessibilityLabel([dayName, dayTitle].compactMap { $0 }.joined(separator: ", "))
            Spacer(minLength: 0)
            // The way to the days either side, on the date's line at the
            // sidebar's right edge: there while the pointer is over the
            // sidebar, gone otherwise. ⌘[ and ⌘] work either way.
            dayArrows
                .opacity(showsDayArrows ? 1 : 0)
                .allowsHitTesting(showsDayArrows)
                .animation(.easeOut(duration: 0.18), value: showsDayArrows)
        }
        // In line with the section titles under it.
        .padding(.leading, 26)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        // What scrolls under the date fades into the sidebar before it
        // reaches it, as under the foot.
        .background {
            EdgeFade(edge: .top)
                .padding(.bottom, -28)
        }
        // And over the date, up through the title bar, nothing at all:
        // the fade is solid only as far as the header's own top, and the
        // rows went on above it, blurred behind the window's buttons.
        .background(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .frame(height: 120)
                .offset(y: -120)
                .allowsHitTesting(false)
        }
    }

    /// Whether the day's arrows show: only while the pointer is over the
    /// sidebar. Not while the keyboard is in it — the sidebar has the
    /// keyboard from the moment the window opens, so they never went away.
    private var showsDayArrows: Bool { isOverSidebar }

    /// Two arrows side by side with nothing behind them: beside the date
    /// a capsule read as a second title. Each is clickable over a box the
    /// height of the date's line, not just the few points of the glyph.
    private var dayArrows: some View {
        HStack(spacing: 0) {
            Button { move(-1) } label: { dayArrow(.chevronBack) }
                .accessibilityLabel("Previous Day")
                .help("Previous day (⌘[)")
                .keyboardShortcut("[", modifiers: .command)
            Button { move(1) } label: { dayArrow(.chevronForward) }
                .accessibilityLabel("Next Day")
                .help("Next day (⌘])")
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.borderless)
        // Click targets, not stops for the keyboard, as the date is: at
        // the head of the sidebar they were the first thing in it, and
        // took the focus — and its ring — when the window opened.
        .focusable(false)
        .fixedSize()
    }

    /// A day arrow in a box as tall as the date's line.
    private func dayArrow(_ icon: LibraryIcon) -> some View {
        Chevron(icon: icon)
            .frame(width: 22, height: 24)
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
        // A recording on its way in: what it is called and how far it is.
        if let importing = coordinator.importStatus {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(importing.line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } header: { header("Importing") }
        }
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

    @ViewBuilder
    private func meetingMenu(_ url: URL) -> some View {
        Button("Show in Finder", systemImage: "folder.fill") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Open in Default App", systemImage: "doc.text") { NSWorkspace.shared.open(url) }
        Divider()
        Button("Move to Trash", systemImage: "minus.circle.fill", role: .destructive) {
            coordinator.forgetVoices(ofMeetingAt: url)
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
                EventView(event: event, coordinator: coordinator,
                          sidebarShown: columns != .detailOnly)
            } else {
                nothingSelected
            }
        case nil:
            nothingSelected
        }
    }

    /// Take Notes, as the sidebar's foot has it — and the empty page, when
    /// the sidebar is hidden and its button with it.
    private var takeNotesButton: some View {
        Button { coordinator.startMeeting() } label: {
            // A record dot and what it does. As wide as its words:
            // the room at its sides is four points more than the
            // room above and below.
            // The pill's ring lime, with a black dot and label in
            // either appearance: the lime is as light in the dark.
            // While a meeting is on it only shows it, and is grey
            // with an ink label: the lime button is the one that
            // starts something.
            let label = liveMeeting == nil ? Color.black : Color(nsColor: .textColor)
            HStack(spacing: 7) {
                Circle()
                    .fill(label)
                    .frame(width: 9, height: 9)
                Text(liveMeeting == nil ? "Take Notes" : "Show Meeting")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(label)
            }
            .padding(.vertical, TakeNotesButtonStyle.vertical)
            .padding(.horizontal, TakeNotesButtonStyle.vertical + 4)
            .contentShape(Capsule())
        }
            .buttonStyle(TakeNotesButtonStyle(ink: liveMeeting == nil))
            .fixedSize()
            .help(liveMeeting == nil ? "Take notes for the meeting on now" : "Show the meeting")
    }

    private var nothingSelected: some View {
        // With the sidebar hidden there is no Take Notes in the window: the
        // page has the button, and its line ends in "or" to lead into it.
        // The line is otherwise the same, and the button keeps its room
        // while it is not shown, so nothing on the page moves when the
        // sidebar comes and goes — and nothing fades: the sidebar's own
        // animation is kept off this page.
        let hidden = columns == .detailOnly
        return ContentUnavailableView {
            Label {
                // The text's own ink — black on light, white on dark — not
                // the grey an empty view gives its label.
                Text("Pick a meeting\nor a dictation on the left" + (hidden ? " or" : "."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(nsColor: .textColor))
            } icon: {
                Glyph(icon: .calendar, size: 48)
            }
        } actions: {
            takeNotesButton
                .padding(.top, 8)
                .opacity(hidden ? 1 : 0)
                // Disabled while it is not shown: a button nobody can see
                // must not take a click, nor the keyboard's focus.
                .disabled(!hidden)
                .accessibilityHidden(!hidden)
        }
        .transaction { $0.animation = nil }
        .navigationTitle("Clio")
        .toolbar { SearchToolbarItem() }
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
    /// With the sidebar open its Take Notes is the window's one ink
    /// button, and the page's is grey beside it; with it hidden the
    /// page's is the only one there is, and takes the ink.
    let sidebarShown: Bool

    private var isOver: Bool { event.end < Date() }

    var body: some View {
        // The page is the one button, in the middle, the size of the
        // onboarding card's: no link — the address is under the ⋯. Its
        // name and time sit over it, and not in the toolbar.
        Group {
            if !isOver {
                VStack(spacing: 0) {
                    // The name breaks onto another line at 320 points,
                    // rather than running the width of the page.
                    Text(event.title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                    // When, on a line; then how long and who, on the next.
                    Text(Self.day(event))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 6)
                    DocumentSubtitle(subtitle: Self.length(event), attendees: event.attendees,
                                     chevronSize: 9)
                        .font(.system(size: 13))
                        .padding(.top, 2)
                    // Notes taken from the call, first; or notes by hand.
                    HStack(spacing: 10) {
                        joinButton
                        writeButton
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, 28)
                // Nothing on the page asks for the keyboard: without this
                // the window's focus ring lands on "2 participants".
                .focusEffectDisabled()
            } else {
                VStack(spacing: 16) {
                    Text("No notes were taken for this meeting.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    writeButton
                }
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The ⋯ where every page has it, bottom right.
        .overlay(alignment: .bottom) {
            DocumentBar {
                EmptyView()
            } trailing: {
                if let url = event.joinURL {
                    MoreMenu {
                        Button("Copy Meeting URL", systemImage: "link") {
                            TextInjector.copy(url.absoluteString)
                        }
                    }
                }
            }
        }
        .navigationTitle(event.title)
        .toolbar {
            if isOver {
                TitleItem {
                    DocumentTitle(title: .constant(event.title), isEditable: false,
                                  subtitle: Self.when(event), attendees: event.attendees)
                }
            }
            SearchToolbarItem()
        }
    }

    /// Notes for the event written by hand, nothing recorded. Recording
    /// can be started from the notes' own page afterwards.
    private var writeButton: some View {
        Button {
            coordinator.writeNotes(for: event)
        } label: {
            PageButtonLabel(title: "Write Notes", dot: false, ink: false)
        }
        .buttonStyle(PageButtonStyle(ink: false))
        .fixedSize()
        .help("Write notes for this event without recording it")
    }

    /// Notes taken from the call: joining it when there is one to join,
    /// just the notes when there is not (a meeting in a room). The
    /// sidebar's record dot, since it is the sidebar's button on a page.
    private var joinButton: some View {
        let ink = !sidebarShown
        return Button {
            coordinator.startMeeting(event: event, join: event.joinURL != nil)
        } label: {
            PageButtonLabel(title: event.joinURL != nil ? "Join & Take Notes" : "Take Notes",
                            dot: true, ink: ink)
        }
        .buttonStyle(PageButtonStyle(ink: ink))
        .fixedSize()
        .help(event.joinURL != nil ? "Join the call and record notes for it" : "Record notes for this meeting")
    }

    static func when(_ event: MeetingEvent) -> String {
        whenLine(start: event.start, end: event.end)
    }

    /// "Wednesday, 18 November 2026 at 09:45": the part of `when` before
    /// how long it runs.
    static func day(_ event: MeetingEvent) -> String {
        let line = when(event)
        return line.range(of: " · ").map { String(line[..<$0.lowerBound]) } ?? line
    }

    /// "30 min": the part of `when` after the date; nil without one.
    static func length(_ event: MeetingEvent) -> String? {
        let line = when(event)
        return line.range(of: " · ").map { String(line[$0.upperBound...]) }
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
    /// The meeting's audio, where Settings had it kept.
    @State private var player = MeetingPlayer()
    @Environment(\.pickEvent) private var pickEvent

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
        .onDisappear {
            player.stop()
            flush()
        }
        // A new summary landed in the file: take it, and only it — the
        // notes here may be newer than the file's.
        // Opened while its meeting was still being recorded or finished,
        // this page looked for audio before any was written: look again
        // whenever the meeting moves on.
        .onChange(of: coordinator.meeting?.phase) { _, _ in
            if !player.hasAudio { player.load(meeting: url) }
        }
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
                coordinator.forgetVoices(ofMeetingAt: url)
                try? library.trash(url)
                selection = nil
            }
        } message: {
            Text("Its notes, summary and transcript go with it. Finder can put it back.")
        }
    }

    private func load() {
        record = library.record(at: url)
        player.load(meeting: url)
        // The summary when there is one; otherwise the notes.
        if record?.summary == nil, !isSummarizing { pane = .notes }
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["CLIO_MEETING_PANE"],
           let chosen = MeetingView.Pane.allCases.first(where: { $0.rawValue.lowercased() == name }) {
            pane = chosen
        }
        // CLIO_ASSIGN_SHOW: "Add to Calendar Event…" chosen from the ⋯, so
        // the picker can be looked at; =<words> gives the notes to the
        // first event with them in its name and says what the file holds.
        if let asked = ProcessInfo.processInfo.environment["CLIO_ASSIGN_SHOW"], let record {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if asked == "1" {
                    pickEvent?(EventPick(day: record.startDate, title: record.title) { assign($0) })
                } else if let event = coordinator.dayEvents(on: record.startDate)
                    .first(where: { $0.title.localizedCaseInsensitiveContains(asked) }) {
                    assign(event)
                    let front = (try? String(contentsOf: url, encoding: .utf8))?
                        .components(separatedBy: "\n").filter { $0.hasPrefix("event") } ?? []
                    FileHandle.standardError.write(Data(
                        "[assign] “\(record.title)” → “\(event.title)”: \(front)\n".utf8))
                }
            }
        }
        // CLIO_PLAY=<seconds>: presses Play, as a click on the control
        // would, and says each second where the playback has got to —
        // the one way to hear a meeting's audio without a hand on it.
        if let seconds = ProcessInfo.processInfo.environment["CLIO_PLAY"].flatMap(Int.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                FileHandle.standardError.write(Data(
                    "[player] audio: \(player.hasAudio) duration: \(player.duration)\n".utf8))
                player.toggle()
                for _ in 0..<seconds {
                    try? await Task.sleep(for: .seconds(1))
                    FileHandle.standardError.write(Data(String(
                        format: "[player] playing: %@ at %.2f\n",
                        "\(player.isPlaying)", player.time).utf8))
                }
                exit(0)
            }
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
                    MarkdownEditor(text: binding(\.notes), placeholder: "Write notes…",
                                   placeholderHeading: "New note",
                                   // A line's time plays the meeting from a
                                   // moment before it was written.
                                   onTime: player.hasAudio ? { player.play(from: max(0, $0 - 5)) } : nil,
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
                    TranscriptList(record: record, isLive: false) { voice, name in
                        guard self.record?.name(voice: voice, as: name, confirmed: true) == true
                        else { return }
                        isDirty = true
                        flush()
                        if let renamed = self.record { coordinator.voicesRenamed(in: renamed) }
                    }
                    .playing(player.hasAudio ? { player.play(from: $0) } : nil)
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
            SearchToolbarItem()
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
                // Notes alone is nothing to choose between.
                if panes(record).count > 1 {
                    PaneMenu(panes: panes(record), pane: $pane)
                }
            } center: {
                if player.hasAudio {
                    PlayerControl(player: player)
                } else if record.lines.isEmpty, !coordinator.isMeetingActive {
                    // Notes written by hand, nothing recorded yet: the
                    // recording can be started here, and goes into them.
                    Button {
                        flush()
                        coordinator.startMeeting(continuing: url)
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Color(nsColor: .textColor)).frame(width: 9, height: 9)
                            Text("Record")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(nsColor: .textColor))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 35)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(BarFill.colour, in: Capsule())
                    .help("Record this meeting; the transcript and summary join these notes")
                }
            } trailing: {
                CopyButton(help: pane.copyHelp) { TextInjector.copy(pane.text(of: record)) }
                // Everything else about the file, beside Copy.
                MoreMenu {
                    Button("Show in Finder", systemImage: "folder.fill") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Open in Default App", systemImage: "doc.text") {
                        NSWorkspace.shared.open(url)
                    }
                    Divider()
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
                    // The day's calendar puts notes under the event they
                    // were taken for; this says which, when it guessed
                    // wrong or could not tell.
                    Button("Add to Calendar Event…", systemImage: "calendar.badge.plus") {
                        pickEvent?(EventPick(day: record.startDate, title: record.title) { assign($0) })
                    }
                    .disabled(pickEvent == nil)
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
    }

    /// Only the panes with something in them: Notes always, Summary once
    /// there is one (or one is being written), Transcript once anything
    /// was said.
    private func panes(_ record: MeetingRecord) -> [MeetingView.Pane] {
        (record.summary != nil || isSummarizing ? [.summary] : [])
            + [.notes]
            + (record.lines.isEmpty ? [] : [.transcript])
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

    /// These are `event`'s notes: it names them, any other notes that
    /// named it let go, and what the notes lack — who was invited, the
    /// call's link — comes from it. The title stays the notes' own.
    private func assign(_ event: MeetingEvent) {
        guard record != nil else { return }
        coordinator.releaseNotes(of: event, except: url)
        record?.link(to: event)
        if record?.attendees.isEmpty == true { record?.attendees = event.attendees }
        if record?.joinURL == nil { record?.joinURL = event.joinURL }
        isDirty = true
        flush()
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
            SearchToolbarItem()
        }
        .overlay(alignment: .bottom) {
            DocumentBar {
                EmptyView()
            } trailing: {
                CopyButton(help: "Copy the dictation") { TextInjector.copy(entry.text) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                MoreMenu {
                    Button("Remove", systemImage: "minus.circle.fill", role: .destructive, action: remove)
                }

            }
        }
    }
}

// MARK: - Shared

/// What was said, in turns. No scroll of its own: it is part of the
/// document's one scroll, under the toolbar.
///
/// A turn is headed "Me", or by the voice that spoke it: its name, or
/// "Speaker 2" until it has one. A voice's heading is a button — click it
/// to say whose voice it is, and every turn of that voice takes the name.
struct TranscriptList: View {
    let record: MeetingRecord
    let isLive: Bool
    /// Names a voice; nil where names cannot be changed.
    var rename: ((Int, String) -> Void)?
    /// Plays the meeting's audio from a time; nil where there is none.
    var play: ((TimeInterval) -> Void)?

    /// The same list, with its times playing the audio from there.
    func playing(_ play: ((TimeInterval) -> Void)?) -> TranscriptList {
        var copy = self
        copy.play = play
        return copy
    }

    @State private var naming: MeetingLine.ID?

    var body: some View {
        let paragraphs = MeetingMarkdown.paragraphs(record.lines)
        LazyVStack(alignment: .leading, spacing: 12) {
            if paragraphs.isEmpty {
                Text(isLive ? "Listening. Lines appear a few seconds after they are said."
                            : "Nothing was transcribed.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(paragraphs) { line in
                VStack(alignment: .leading, spacing: 2) {
                    heading(line)
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: MarkdownStyle.ink))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(line.id)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heading(_ line: MeetingLine) -> some View {
        let font = Font.system(size: 11, weight: .semibold)
        if let voice = line.voice, line.speaker == .others, let rename {
            HStack(spacing: 0) {
                Button {
                    naming = line.id
                } label: {
                    Text(record.label(for: line))
                        .font(font)
                        .foregroundStyle(VoiceColor.of(voice))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(record.voices[voice] == nil ? "Say who this is" : "Change the name")
                .popover(isPresented: Binding(get: { naming == line.id },
                                              set: { if !$0 { naming = nil } }),
                         arrowEdge: .bottom) {
                    VoiceNamePopover(
                        voice: voice,
                        current: record.voices[voice],
                        suggestions: suggestions(for: voice),
                        done: { name in
                            naming = nil
                            if let name { rename(voice, name) }
                        })
                }
                Text(" · ").font(font).foregroundStyle(.secondary)
                time(line, colour: .secondary)
            }
        } else {
            let colour = line.speaker == .me ? Color.accentColor
                : line.voice.map(VoiceColor.of) ?? .secondary
            HStack(spacing: 0) {
                Text("\(record.label(for: line)) · ").font(font).foregroundStyle(colour)
                time(line, colour: colour)
            }
        }
    }

    /// When the line was said — and, where the meeting's audio was kept,
    /// a button that plays it from there.
    @ViewBuilder
    private func time(_ line: MeetingLine, colour: Color) -> some View {
        let label = Text(line.timestamp)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(colour)
        if let play {
            Button { play(line.start) } label: { label.underline().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Play from here")
        } else {
            label
        }
    }

    /// Those invited who are not already another voice's name.
    private func suggestions(for voice: Int) -> [String] {
        let taken = Set(record.voices.filter { $0.key != voice }.map { $0.value.name.lowercased() })
        return record.attendees
            .filter { !$0.declined && !$0.name.isEmpty && !$0.name.contains("@") }
            .map(\.name)
            .filter { !taken.contains($0.lowercased()) }
    }
}

/// A colour per voice, so turns can be told apart at a glance before any
/// has a name. Quiet ones: the accent stays "Me".
enum VoiceColor {
    static let palette: [Color] = [.secondary, .teal, .orange, .purple, .pink, .brown, .indigo, .mint]

    static func of(_ voice: Int) -> Color {
        palette[(max(1, voice) - 1) % palette.count]
    }
}

/// Whose voice is this: a field, those invited to pick from, and a way
/// back to "Speaker 2".
private struct VoiceNamePopover: View {
    let voice: Int
    let current: MeetingVoice?
    let suggestions: [String]
    /// The name to give, an empty one to take it away, nil to leave it.
    let done: (String?) -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current == nil ? "Who is \(MeetingRecord.placeholder(voice))?" : "Who is this?")
                .font(.system(size: 12, weight: .semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { done(name) }
                .frame(width: 220)
            if current?.confirmed == false {
                Text("Clio worked this name out from the transcript. Press Return to keep it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(suggestions.prefix(8), id: \.self) { suggestion in
                        Button(suggestion) { done(suggestion) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }
            HStack {
                if current != nil {
                    Button("Remove Name") { done("") }
                }
                Spacer()
                Button("Save") { done(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(14)
        .onAppear {
            name = current?.name ?? ""
            focused = true
        }
    }
}

/// A button on a page — an event's Take Notes and Write Notes: as wide as
/// what it says, with four points more room at its sides than above and
/// below, the sidebar's record dot where it records. In ink where it is
/// the window's main button; grey with an ink label where it is not.
struct PageButtonLabel: View {
    let title: String
    let dot: Bool
    let ink: Bool

    /// Room above and below the label.
    static let vertical: CGFloat = 10

    private var colour: Color {
        ink ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textColor)
    }

    var body: some View {
        HStack(spacing: 8) {
            if dot {
                Circle().fill(colour).frame(width: 10, height: 10)
            }
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colour)
                .lineLimit(1)
        }
        .padding(.vertical, Self.vertical)
        .padding(.horizontal, Self.vertical + 4)
        .contentShape(Capsule())
    }
}

struct PageButtonStyle: ButtonStyle {
    let ink: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ink ? Color(nsColor: .textColor).opacity(configuration.isPressed ? 0.75 : 1)
                            : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08),
                        in: Capsule())
    }
}

/// Take Notes: a capsule in the pill's ring lime, as wide as what it says. The label brings
/// its own padding — the sides four points more than top and bottom.
struct TakeNotesButtonStyle: ButtonStyle {
    /// Above and below the label: with 13-point type, the 35 points the
    /// bar's other controls stand.
    static let vertical: CGFloat = 9.5
    /// Lime, for the button that starts something; the bar's grey for one
    /// that only shows what is already going on.
    var ink = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // The lime the activity ring sweeps through while a dictation
            // is transcribed (`ActivityRing.lime`); the label on it is
            // black, set where the label is made.
            .background(ink ? ActivityRing.lime.opacity(configuration.isPressed ? 0.75 : 1)
                            : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08),
                        in: Capsule())
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
