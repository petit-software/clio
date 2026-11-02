import AppKit
import SwiftUI
import ClioCore

/// What the library window is showing.
public enum LibrarySelection: Hashable, Sendable {
    /// The meeting being recorded now.
    case live
    case meeting(URL)
    case dictation(UUID)
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
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 440)
        // A real toolbar, and SwiftUI's toolbar and title bridged into it.
        // Without one the split view has nothing to float under: the sidebar
        // was a flat column, and the toolbar buttons plain icons, instead of
        // the glass macOS 26 draws for a window built this way.
        let toolbar = NSToolbar(identifier: "ClioLibrary")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // No line under the toolbar: it is glass over the document, and the
        // soft scroll edge is where the two meet.
        window.titlebarSeparatorStyle = .none
        let host = NSHostingView(rootView: LibraryView(coordinator: coordinator))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setFrameAutosaveName("ClioLibraryWindow")
        if !window.setFrameUsingName("ClioLibraryWindow") { window.center() }
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

    private var library: MeetingLibrary? { coordinator.library }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            detail
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
        .softTopEdge()
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
            if let meeting = liveMeeting {
                Section("Now") {
                    selectable(.live) { LiveRow(meeting: meeting) }
                }
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.files) { file in
                        selectable(.meeting(file.url)) { MeetingRow(file: file) }
                            .contextMenu { meetingMenu(file.url) }
                    }
                }
            }

            if !dictations.isEmpty {
                Section("Dictations") {
                    ForEach(dictations) { entry in
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
                }
            }
        }
        .listStyle(.sidebar)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .overlay {
            if library?.hasLoaded == true, groups.isEmpty, liveMeeting == nil, dictations.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No meetings yet" : "Nothing found",
                          systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass")
                } description: {
                    Text(query.isEmpty
                         ? "Take notes during a call and they appear here."
                         : "No meeting mentions “\(query)”.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if liveMeeting == nil {
                Button {
                    coordinator.startMeeting()
                } label: {
                    Label("Take Notes", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton(prominent: true)
                .padding(12)
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
        (liveMeeting == nil ? [] : [.live])
            + groups.flatMap { $0.files.map { .meeting($0.url) } }
            + dictations.map { .dictation($0.id) }
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
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView("No meeting selected", systemImage: "doc.text",
                               description: Text("Pick one on the left."))
    }
}

// MARK: - Rows

private struct LiveRow: View {
    @Bindable var meeting: MeetingSession

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
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
        .padding(.vertical, 3)
    }
}

private struct DictationRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
                .font(.system(size: 12))
                .lineLimit(2)
            Text(entry.date, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
    /// toolbar: what it was, then the pane picked in the toolbar.
    private func document(_ record: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Meeting", text: binding(\.title))
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .bold))
                    Text(Self.when(record))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if !record.attendees.isEmpty {
                        Text(record.attendees
                            .map { $0.declined ? "\($0.name) (declined)" : $0.name }
                            .joined(separator: ", "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 22)

                switch pane {
                case .notes:
                    MarkdownEditor(text: binding(\.notes), placeholder: "Notes, in Markdown.",
                                   minHeight: 320)
                        .padding(.horizontal, 8)
                case .summary:
                    SummaryText(markdown: record.summary ?? "")
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .transcript:
                    TranscriptList(lines: record.lines, isLive: false)
                }
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softTopEdge()
        #if DEBUG
        // For the tools: open scrolled to the end, so the toolbar has the
        // document passing under it to be judged against.
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["CLIO_LIBRARY_SCROLLED"] != nil
                             ? .bottom : nil)
        #endif
        .toolbar {
            // The view switcher, centred in the toolbar.
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $pane) {
                    ForEach(panes(record)) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // Top right, always — the same place for a meeting and a dictation.
            TrailingToolbarActions {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingMarkdown.render(record), forType: .string)
                } label: { Label("Copy as Markdown", systemImage: "square.fill.on.square.fill") }
                    .help("Copy the whole meeting as Markdown")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Label("Show in Finder", systemImage: "folder.fill") }
                    .help("Show in Finder")
                Button(role: .destructive) {
                    confirmingTrash = true
                } label: { Label("Move to Trash", systemImage: "minus.circle.fill") }
                    .help("Move to Trash")
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
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        var text = day.string(from: record.startDate)
        if let end = record.endDate {
            let minutes = Int(end.timeIntervalSince(record.startDate) / 60)
            text += " · \(minutes < 1 ? "under a minute" : "\(minutes) min")"
        }
        return text
    }
}

// MARK: - A dictation

private struct DictationView: View {
    let entry: TranscriptEntry
    let remove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.date.formatted(date: .complete, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.system(size: 16))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .softTopEdge()
        // Top right, as a meeting's are.
        .toolbar {
            TrailingToolbarActions {
                Button {
                    TextInjector.copy(entry.text)
                } label: { Label("Copy", systemImage: "square.fill.on.square.fill") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the dictation")
                Button(role: .destructive, action: remove) {
                    Label("Remove", systemImage: "minus.circle.fill")
                }
                .help("Remove it from the history")
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
