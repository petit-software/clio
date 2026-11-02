import AppKit
import SwiftUI
import ClioCore

/// The meeting window: an ordinary titled window, because it is a document
/// the user keeps beside the call, types into, and comes back to.
@MainActor
final class MeetingWindowController {
    private var window: NSWindow?

    func show(meeting: MeetingSession, coordinator: AppCoordinator) {
        let view = MeetingView(meeting: meeting, coordinator: coordinator)
        if let window {
            window.contentView = NSHostingView(rootView: view)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Meeting Notes"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 420)
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("ClioMeetingWindow")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if let warning {
                warningBanner(warning)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Picker("", selection: $pane) {
                ForEach(panes) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch pane {
                case .notes: notesPane
                case .transcript: transcriptPane
                case .summary: summaryPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
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
        .onChange(of: meeting.phase) { _, phase in
            if phase == .finished, meeting.record.summary != nil { pane = .summary }
        }
    }

    private var panes: [Pane] {
        meeting.record.summary == nil && meeting.phase != .summarizing
            ? [.notes, .transcript] : Pane.allCases
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Meeting", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .onSubmit { meeting.setTitle(title) }

            HStack(spacing: 8) {
                statusDot
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if !meeting.record.attendees.isEmpty {
                Text(meeting.record.attendees
                    .map { $0.declined ? "\($0.name) (declined)" : $0.name }
                    .joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help("Invited, from your calendar")
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch meeting.phase {
        case .starting, .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .finishing, .summarizing:
            ProgressView().controlSize(.mini)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
        }
    }

    private var statusLine: String {
        let time = MeetingLine.timestamp(meeting.elapsed)
        let behind = meeting.pendingChunks > 0
            ? " · transcribing \(meeting.pendingChunks) behind" : ""
        switch meeting.phase {
        case .starting: return "Starting…"
        case .recording: return "Recording · \(time)\(behind)"
        case .finishing:
            return meeting.pendingChunks > 0
                ? "Finishing the transcript · \(meeting.pendingChunks) left"
                : "Finishing the transcript…"
        case .summarizing: return "Writing the summary…"
        case .finished: return "Saved · \(time)"
        case .failed(let reason): return reason
        }
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
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    static func openSystemAudioSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Panes

    private var notesPane: some View {
        TextEditor(text: $notes)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .overlay(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Your notes. They guide the summary.")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
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
        let paragraphs = MeetingMarkdown.paragraphs(meeting.record.lines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if paragraphs.isEmpty {
                        Text(meeting.isActive ? "Listening. Lines appear a few seconds after they are said."
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
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: paragraphs.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var summaryPane: some View {
        ScrollView {
            Group {
                if let summary = meeting.record.summary {
                    SummaryText(markdown: summary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing the summary on this Mac…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let url = meeting.fileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Copy Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.record.transcriptText, forType: .string)
                }
                .disabled(meeting.record.lines.isEmpty)
            }
            Spacer()
            if meeting.isActive {
                Button("Stop Recording") {
                    meeting.setTitle(title)
                    meeting.setNotes(notes)
                    coordinator.stopMeeting()
                }
                .keyboardShortcut(".", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if meeting.phase == .finished, let url = meeting.fileURL {
                Button("Open Notes") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
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
