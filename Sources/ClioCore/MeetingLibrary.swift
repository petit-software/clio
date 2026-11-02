import Foundation
import Observation

/// One meeting in the folder, as much as the sidebar needs.
public struct MeetingFile: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public var url: URL
    public var title: String
    public var start: Date
    public var end: Date?
    public var attendees: [MeetingAttendee]
    /// A line to show under the title: the summary's first point, else the
    /// notes', else the first thing said.
    public var preview: String
    /// Everything in the file, lowercased, for search.
    var searchText: String
}

/// Every meeting in the notes folder.
///
/// The folder is the library: no index, no database. Each Markdown file is
/// read back with `MeetingMarkdown.parse`, and the folder is watched, so a
/// file renamed, edited or deleted in Finder or another editor shows up here
/// as it is. Edits made here are written back to the file.
@MainActor
@Observable
public final class MeetingLibrary {
    public private(set) var folder: URL
    /// Newest first.
    public private(set) var files: [MeetingFile] = []
    public private(set) var hasLoaded = false

    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: Task<Void, Never>?

    public init(folder: URL) {
        self.folder = folder
        reload()
        watch()
    }

    /// Points the library at another folder — Settings changed it.
    public func setFolder(_ folder: URL) {
        guard folder.standardizedFileURL != self.folder.standardizedFileURL else { return }
        self.folder = folder
        watcher?.cancel()
        watcher = nil
        files = []
        reload()
        watch()
    }

    /// Reads the folder again, off the main actor.
    public func reload() {
        let folder = folder
        Task { @MainActor in
            let scanned = await Task.detached(priority: .userInitiated) {
                Self.scan(folder)
            }.value
            guard folder == self.folder else { return }
            files = scanned
            hasLoaded = true
        }
    }

    /// The files whose title, people, notes, summary or transcript contain
    /// every word of `query`.
    public func search(_ query: String) -> [MeetingFile] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return files }
        return files.filter { file in words.allSatisfy { file.searchText.contains($0) } }
    }

    /// The whole meeting in a file, read now.
    public func record(at url: URL) -> MeetingRecord? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MeetingMarkdown.parse(text, fallbackDate: Self.fileDate(url))
    }

    /// Writes an edited meeting back. Returns the file's URL, which moves
    /// when the title changes.
    @discardableResult
    public func save(_ record: MeetingRecord, at url: URL) throws -> URL {
        let written = try MeetingMarkdown.write(record, to: url.deletingLastPathComponent(),
                                                replacing: url)
        scheduleReload()
        return written
    }

    /// To the Trash, not gone: Finder can put it back.
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        files.removeAll { $0.url == url }
        scheduleReload()
    }

    // MARK: Grouping

    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String { title }
        public var title: String
        public var files: [MeetingFile]
    }

    /// Today, Yesterday, then a group per month — newest first throughout.
    public nonisolated static func groups(_ files: [MeetingFile], now: Date = Date(),
                                          calendar: Calendar = .current) -> [Group] {
        let month = DateFormatter()
        month.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var groups: [Group] = []
        for file in files.sorted(by: { $0.start > $1.start }) {
            let title: String
            if calendar.isDate(file.start, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(file.start, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else {
                title = month.string(from: file.start)
            }
            if groups.last?.title == title {
                groups[groups.count - 1].files.append(file)
            } else {
                groups.append(Group(title: title, files: [file]))
            }
        }
        return groups
    }

    // MARK: Reading the folder

    nonisolated static func scan(_ folder: URL) -> [MeetingFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap(file(at:))
            .sorted { $0.start > $1.start }
    }

    nonisolated static func file(at url: URL) -> MeetingFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let record = MeetingMarkdown.parse(text, fallbackDate: fileDate(url))
        else { return nil }
        return MeetingFile(url: url, title: record.title, start: record.startDate,
                           end: record.endDate, attendees: record.attendees,
                           preview: preview(of: record),
                           searchText: text.lowercased())
    }

    nonisolated static func preview(of record: MeetingRecord) -> String {
        func firstLine(_ text: String?) -> String? {
            text?.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { line in
                    var line = line
                    for mark in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(mark) {
                        line = String(line.dropFirst(mark.count))
                    }
                    return line
                }
        }
        return firstLine(record.summary) ?? firstLine(record.notes)
            ?? record.lines.first?.text ?? ""
    }

    nonisolated static func fileDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
    }

    // MARK: Watching

    /// Anything added, removed or replaced in the folder — Clio's own
    /// atomic writes included — reloads it, a moment later.
    private func watch() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}
