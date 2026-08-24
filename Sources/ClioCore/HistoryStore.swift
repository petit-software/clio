import Foundation
import Observation

public struct TranscriptEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }

    /// One line, for a menu item.
    public var menuLabel: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 48
            ? String(collapsed.prefix(48)) + "…"
            : collapsed
    }
}

/// The last N transcripts (§4).
///
/// In memory by default and written to disk only if the user asks. Dictated
/// text is whatever the user happened to say — a log of it on disk should be
/// something they opt into, not something they discover later.
@MainActor
@Observable
public final class HistoryStore {

    public static let limit = 20

    public private(set) var entries: [TranscriptEntry] = []

    /// Turning this on writes what is already in memory; turning it off
    /// deletes the file, so switching it off is not merely "stop appending".
    public var persistsToDisk: Bool {
        didSet {
            guard persistsToDisk != oldValue else { return }
            persistsToDisk ? save() : deleteFile()
        }
    }

    private let fileURL: URL

    public init(fileURL: URL = AppPaths.supportDirectory
                    .appendingPathComponent("history.json"),
                persistsToDisk: Bool = false) {
        self.fileURL = fileURL
        self.persistsToDisk = persistsToDisk
        if persistsToDisk { entries = Self.load(from: fileURL) ?? [] }
    }

    public var latest: TranscriptEntry? { entries.first }

    public func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(TranscriptEntry(text: trimmed), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        if persistsToDisk { save() }
    }

    public func clear() {
        entries = []
        if persistsToDisk { save() } else { deleteFile() }
    }

    // MARK: Persistence

    private static func load(from url: URL) -> [TranscriptEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TranscriptEntry].self, from: data)
    }

    private func save() {
        guard persistsToDisk else { return }
        do {
            try AppPaths.ensureDirectories()
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience; a failure to write it must not
            // interrupt dictation.
        }
    }

    private func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
