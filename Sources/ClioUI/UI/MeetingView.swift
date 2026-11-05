import AppKit
import SwiftUI
import ClioCore

/// The meeting being recorded, in the library window: what it is, how it is
/// going, the user's notes, and the transcript arriving.
struct MeetingView: View {
    @Bindable var meeting: MeetingSession
    let coordinator: AppCoordinator

    enum Pane: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        case summary = "Summary"
        var id: String { rawValue }
    }


    @State private var pane: Pane = .notes
    @State private var title = ""
    @State private var notes = ""
    @State private var notesSave: Task<Void, Never>?
    @State private var titleSave: Task<Void, Never>?
    private static let end = "end"

    var body: some View {
        // One page that scrolls under the window's glass toolbar; Stop
        // floats over it on a glass bar of its own.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The recorder is at the foot (`MeetingPill`); the page
                    // starts where a saved meeting's does.
                    Color.clear.frame(height: 12)

                    if let warning {
                        warningBanner(warning)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 18)
                    }

                    switch pane {
                    case .notes: notesPane
                    case .transcript: transcriptPane
                    case .summary: summaryPane
                    }

                    // Room at the end, so the last line clears the bar.
                    Color.clear.frame(height: 90).id(Self.end)
                }
                .pageMargins()
            }
            .nativeTopEdge()
            .pageTopFade()
            .thinScrollers()
            // The newest line, as it arrives, while the transcript is showing.
            .onChange(of: meeting.record.lines.count) { _, _ in
                guard pane == .transcript else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
        .overlay(alignment: .bottom) { actionBar }
        // The name and date are drawn in the toolbar, the name edited
        // there.
        .toolbar {
            TitleItem {
                DocumentTitle(title: $title,
                              subtitle: meeting.record.startDate.formatted(date: .complete, time: .shortened),
                              attendees: meeting.record.attendees)
            }
            TrailingToolbarActions {
                MoreMenu {
                    Button("Show in Finder", systemImage: "folder.fill") {
                        if let url = meeting.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(meeting.fileURL == nil)
                    // Each part on its own; the foot's Copy takes the pane showing.
                    Button("Copy Notes", systemImage: "note.text") { TextInjector.copy(notes) }
                        .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Copy Summary", systemImage: "text.badge.star") {
                        TextInjector.copy(meeting.record.titledSummary ?? "")
                    }
                    .disabled(meeting.record.summary == nil)
                    Button("Copy Transcript", systemImage: "text.quote") {
                        TextInjector.copy(meeting.record.transcriptText)
                    }
                    .disabled(meeting.record.lines.isEmpty)
                    Button("Copy Meeting as Markdown", systemImage: "doc.plaintext") {
                        TextInjector.copy(MeetingMarkdown.render(meeting.record))
                    }
                    if let link = meeting.record.joinURL {
                        Button("Copy Meeting URL", systemImage: "link") {
                            TextInjector.copy(link.absoluteString)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .frame(minWidth: 420, minHeight: 420)
        .onAppear {
            title = meeting.record.title
            notes = meeting.record.notes
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["CLIO_MEETING_PANE"],
               let chosen = Pane.allCases.first(where: { $0.rawValue.lowercased() == name }) {
                pane = chosen
            }
            #endif
        }
        // The title can change under the field: the calendar names the
        // meeting a moment after it starts.
        .onChange(of: meeting.record.title) { _, new in
            if new != title { title = new }
        }
        // Saved as typed in the toolbar, a beat later, and on leaving.
        .onChange(of: title) { _, new in
            titleSave?.cancel()
            titleSave = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                meeting.setTitle(new)
            }
        }
        .onDisappear { meeting.setTitle(title) }
        .onChange(of: meeting.phase) { _, phase in
            if phase == .finished, meeting.record.summary != nil { pane = .summary }
        }
    }

    private var panes: [Pane] {
        meeting.record.summary == nil && meeting.phase != .summarizing
            ? [.notes, .transcript] : Pane.allCases
    }

    // MARK: Problems

    private struct Warning {
        let text: String
        let action: (title: String, run: () -> Void)?
    }

    private var warning: Warning? {
        if let problem = meeting.microphoneProblem {
            return Warning(text: problem, action: nil)
        }
        if let problem = meeting.transcriptionProblem {
            return Warning(text: problem + " Check Settings ▸ Model.", action: nil)
        }
        if let problem = meeting.saveProblem {
            return Warning(text: "The notes could not be saved: \(problem)", action: nil)
        }
        guard meeting.isActive else { return nil }
        switch meeting.systemAudio {
        case .silent:
            return Warning(
                text: "Nothing heard from the call yet. If others are talking, allow Clio "
                    + "under System Audio Recording in Privacy & Security.",
                action: ("Open Privacy Settings", Self.openSystemAudioSettings))
        case .unavailable(let reason):
            return Warning(text: "Only your microphone is being recorded. \(reason)",
                           action: nil)
        case .starting, .listening:
            return nil
        }
    }

    private func warningBanner(_ warning: Warning) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(warning.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if let action = warning.action {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                        .glassButton()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous),
                      tint: .orange.opacity(0.45))
    }

    static func openSystemAudioSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Panes

    private var notesPane: some View {
        MarkdownEditor(text: $notes,
                       placeholder: "Your notes, in Markdown. They guide the summary.",
                       focusOnAppear: meeting.isActive, minHeight: 320)
            .padding(.horizontal, 8)
            // Saved a beat after typing stops, not on every key.
            .onChange(of: notes) { _, new in
                notesSave?.cancel()
                notesSave = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    meeting.setNotes(new)
                }
            }
            .onDisappear { meeting.setNotes(notes) }
    }

    private var transcriptPane: some View {
        TranscriptList(lines: meeting.record.lines, isLive: meeting.isActive)
    }

    private var summaryPane: some View {
        Group {
            if let summary = meeting.record.titledSummary {
                MarkdownEditor(text: .constant(summary), isEditable: false, minHeight: 0)
                    .padding(.horizontal, -20)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the summary on this Mac…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var panePicker: some View {
        PaneMenu(panes: panes, pane: $pane)
    }

    /// Along the foot: the pane on the left, the recorder — and Stop — in
    /// the middle, what to do with the file on the right.
    private var actionBar: some View {
        DocumentBar {
            panePicker
        } center: {
            MeetingPill(meeting: meeting) {
                meeting.setTitle(title)
                meeting.setNotes(notes)
                coordinator.stopMeeting()
            }
        } trailing: {
                CopyButton(help: pane.copyHelp) {
                    TextInjector.copy(pane == .notes ? notes : pane.text(of: meeting.record))
                }
                if meeting.phase == .finished, let url = meeting.fileURL {
                    Button("Open Notes", systemImage: "doc.text") { NSWorkspace.shared.open(url) }
                        .glassButton(prominent: true)
                }
        }
    }
}

/// The summary's Markdown, drawn: the model writes "### " headings, "- "
/// bullets and "- [ ] " next steps, which inline Markdown parsing leaves as
/// they are typed.
struct SummaryText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()),
                    id: \.offset) { _, raw in
                line(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ line: String) -> some View {
        if line.isEmpty {
            Spacer().frame(height: 4)
        } else if let heading = Self.strip(line, prefixes: ["### ", "## ", "# "]) {
            Text(inline(heading))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 6)
        } else if let task = Self.strip(line, prefixes: ["- [ ] ", "* [ ] "]) {
            bullet("☐", task)
        } else if let done = Self.strip(line, prefixes: ["- [x] ", "* [x] "]) {
            bullet("☑", done)
        } else if let item = Self.strip(line, prefixes: ["- ", "* ", "• "]) {
            bullet("•", item)
        } else {
            Text(inline(line)).font(.system(size: 13))
        }
    }

    private func bullet(_ mark: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(.secondary)
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    static func strip(_ line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }
}

extension MeetingView.Pane {
    /// What Copy copies: the pane on screen, as text — the notes as the
    /// Markdown typed, the summary as the model wrote it, the transcript
    /// in turns.
    func text(of record: MeetingRecord) -> String {
        switch self {
        case .notes: return record.notes
        case .summary: return record.titledSummary ?? ""
        case .transcript: return record.transcriptText
        }
    }

    var copyHelp: String {
        switch self {
        case .notes: return "Copy the notes"
        case .summary: return "Copy the summary"
        case .transcript: return "Copy the transcript"
        }
    }
}
