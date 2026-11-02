import Foundation

/// Which side of the call a line came from. The two streams are recorded
/// separately, so this is known for free: the microphone is the person at
/// this Mac, the system audio is everyone else.
public enum MeetingSpeaker: String, Codable, Sendable {
    case me
    case others

    public var label: String {
        switch self {
        case .me: return "Me"
        case .others: return "Others"
        }
    }
}

/// One transcribed chunk of speech.
public struct MeetingLine: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var speaker: MeetingSpeaker
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), speaker: MeetingSpeaker,
                start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    /// "04:07", or "1:04:07" past the hour.
    public var timestamp: String { Self.timestamp(start) }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

public struct MeetingAttendee: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var declined: Bool

    public init(name: String, declined: Bool = false) {
        self.name = name
        self.declined = declined
    }
}

/// Everything about one meeting: what it was, who was there, what was said,
/// and what the user wrote.
public struct MeetingRecord: Sendable, Equatable {
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var attendees: [MeetingAttendee] = []
    public var notes = ""
    public var summary: String?
    public var joinURL: URL?
    /// Ordered by start time, whichever stream finished transcribing first.
    public internal(set) var lines: [MeetingLine] = []

    public init(title: String, startDate: Date = Date()) {
        self.title = title
        self.startDate = startDate
    }

    /// Adds a line in time order, unless it is the other side's words heard
    /// a second time through the microphone.
    ///
    /// On speakers rather than headphones the microphone hears the call as
    /// well as the user, and every line the others say would come back as
    /// "Me". Each stream is transcribed as it arrives, in either order, so
    /// the check runs both ways: a "Me" line that repeats an "Others" line
    /// already here is not added, and an "Others" line removes the "Me"
    /// lines that turn out to have been its echo.
    @discardableResult
    public mutating func add(_ line: MeetingLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var line = line
        line.text = text

        switch line.speaker {
        case .me:
            if lines.contains(where: { $0.speaker == .others && Self.isEcho(line, of: $0) }) {
                return false
            }
        case .others:
            lines.removeAll { $0.speaker == .me && Self.isEcho($0, of: line) }
        }

        let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
        lines.insert(line, at: index)
        return true
    }

    /// Whether `mine` is mostly the words of `theirs`, said at about the
    /// same time. Words, not characters: the two transcriptions of one
    /// sentence differ in punctuation and the odd word, never in most words.
    static func isEcho(_ mine: MeetingLine, of theirs: MeetingLine) -> Bool {
        let slack: TimeInterval = 3
        guard mine.start < theirs.end + slack, theirs.start < mine.end + slack else {
            return false
        }
        let myWords = words(mine.text)
        guard myWords.count >= 3 else { return false }
        var theirCounts: [String: Int] = [:]
        for word in words(theirs.text) { theirCounts[word, default: 0] += 1 }
        var shared = 0
        for word in myWords where (theirCounts[word] ?? 0) > 0 {
            theirCounts[word]! -= 1
            shared += 1
        }
        return Double(shared) / Double(myWords.count) >= 0.6
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    /// The transcript as plain lines, for the summary and for copying.
    public var transcriptText: String {
        MeetingMarkdown.paragraphs(lines)
            .map { "[\($0.timestamp)] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }
}

/// Reads and writes nothing but the one Markdown file per meeting — the
/// file is the meeting, in a folder the user can open with anything.
public enum MeetingMarkdown {

    /// `~/Documents/Clio Meetings`, unless Settings names another folder.
    public static func folder(customPath: String?) -> URL {
        if let customPath, !customPath.isEmpty {
            return URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Clio Meetings", isDirectory: true)
    }

    /// "2026-11-02 14.00 Weekly sync.md". Sorts by date in Finder, and the
    /// time keeps two meetings with one name apart.
    public static func fileName(for record: MeetingRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let title = record.title.components(separatedBy: unsafe).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let name = "\(formatter.string(from: record.startDate)) \(title.isEmpty ? "Meeting" : title)"
        return String(name.prefix(120)) + ".md"
    }

    public static func render(_ record: MeetingRecord) -> String {
        // The facts a program needs, in front matter — Obsidian and most
        // Markdown tools hide it — so reading the file back never means
        // parsing a date written for a person in their own locale.
        var out: [String] = ["---", "clio: 1", "start: \(iso.string(from: record.startDate))"]
        if let end = record.endDate { out.append("end: \(iso.string(from: end))") }
        if let url = record.joinURL { out.append("link: \(url.absoluteString)") }
        out += ["---", "", "# \(record.title)", ""]

        let day = DateFormatter()
        day.dateStyle = .medium
        day.timeStyle = .short
        let time = DateFormatter()
        time.timeStyle = .short
        if let end = record.endDate {
            out.append("**Date:** \(day.string(from: record.startDate)) – \(time.string(from: end))  ")
        } else {
            out.append("**Date:** \(day.string(from: record.startDate)) (in progress)  ")
        }
        if !record.attendees.isEmpty {
            let names = record.attendees.map { $0.declined ? "\($0.name) (declined)" : $0.name }
            out.append("**Attendees:** \(names.joined(separator: ", "))  ")
        }
        if let url = record.joinURL {
            out.append("**Link:** <\(url.absoluteString)>  ")
        }
        out.append("")

        let notes = record.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        out += ["## Notes", "", notes.isEmpty ? "*No notes.*" : notes, ""]

        if let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            out += ["## Summary", "", summary, ""]
        }

        out += ["## Transcript", ""]
        let paragraphs = paragraphs(record.lines)
        if paragraphs.isEmpty {
            out.append("*Nothing transcribed yet.*")
        } else {
            for line in paragraphs {
                out += ["**[\(line.timestamp)] \(line.speaker.label):** \(line.text)", ""]
            }
        }
        return out.joined(separator: "\n")
    }

    /// Writes the record, atomically, replacing the file it was written to
    /// last time. Returns where it went.
    @discardableResult
    public static func write(_ record: MeetingRecord, to folder: URL,
                             replacing previous: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = availableURL(in: folder, for: fileName(for: record), keeping: previous)
        try Data(render(record).utf8).write(to: url, options: .atomic)
        // Renamed: the title changed since the last write.
        if let previous, previous.standardizedFileURL != url.standardizedFileURL {
            try? FileManager.default.removeItem(at: previous)
        }
        return url
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: Reading

    /// The meeting a file describes. Reads what `render` writes, and is
    /// forgiving of a file edited by hand: anything it cannot place is left
    /// out rather than failing the whole meeting. Nil only for a file that is
    /// not a meeting at all — no title and no transcript.
    ///
    /// - Parameter fallbackDate: used when the front matter is gone, as for
    ///   a note written by hand — the file's own date.
    public static func parse(_ text: String, fallbackDate: Date = Date()) -> MeetingRecord? {
        var lines = text.components(separatedBy: "\n")
        var front: [String: String] = [:]
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<close] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                front[key] = value
            }
            lines.removeSubrange(0...close)
        }

        var title: String?
        var section: String?
        var sections: [String: [String]] = [:]
        var attendees: [MeetingAttendee] = []
        for line in lines {
            if title == nil, line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            // Only Clio's own sections. Notes are Markdown and have "## "
            // headings of their own, which belong to the notes.
            if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                if sectionNames.contains(name) {
                    section = name
                    continue
                }
            }
            if section == nil, line.hasPrefix("**Attendees:**") {
                attendees = line.dropFirst("**Attendees:**".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: ", ")
                    .filter { !$0.isEmpty }
                    .map { name in
                        name.hasSuffix(" (declined)")
                            ? MeetingAttendee(name: String(name.dropLast(" (declined)".count)),
                                              declined: true)
                            : MeetingAttendee(name: name)
                    }
                continue
            }
            if let section { sections[section, default: []].append(line) }
        }

        let transcript = (sections["transcript"] ?? []).compactMap(transcriptLine)
        guard title != nil || !transcript.isEmpty else { return nil }

        let start = front["start"].flatMap(iso.date(from:)) ?? fallbackDate
        var record = MeetingRecord(title: title ?? "Meeting", startDate: start)
        record.endDate = front["end"].flatMap(iso.date(from:))
        record.joinURL = front["link"].flatMap(URL.init(string:))
        record.attendees = attendees
        let notes = block(sections["notes"])
        record.notes = notes == "*No notes.*" ? "" : notes
        let summary = block(sections["summary"])
        record.summary = summary.isEmpty ? nil : summary
        // Straight in, in file order: these were checked for echo when they
        // were first said.
        record.lines = transcript
        return record
    }

    static let sectionNames: Set<String> = ["notes", "summary", "transcript"]

    private static func block(_ lines: [String]?) -> String {
        (lines ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "**[04:07] Others:** text" → a line at 247 s.
    static func transcriptLine(_ raw: String) -> MeetingLine? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("**["), let close = line.range(of: "]"),
              let labelEnd = line.range(of: ":**") else { return nil }
        let stamp = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
        let label = line[close.upperBound..<labelEnd.lowerBound].trimmingCharacters(in: .whitespaces)
        let text = line[labelEnd.upperBound...].trimmingCharacters(in: .whitespaces)
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, !text.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        let speaker: MeetingSpeaker = label.lowercased() == "me" ? .me : .others
        return MeetingLine(speaker: speaker, start: seconds, end: seconds, text: text)
    }

    /// `name` in `folder`, or "name 2", "name 3"… if another meeting has
    /// it. Two meetings with one title in one minute — the same untitled
    /// meeting started twice — would otherwise share a file, the second
    /// writing over the first. `previous` is this meeting's own file, which
    /// it may always write again.
    static func availableURL(in folder: URL, for name: String, keeping previous: URL?) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let own = previous?.standardizedFileURL
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while candidate.standardizedFileURL != own,
              FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(number).md")
            number += 1
        }
        return candidate
    }

    /// Consecutive lines from one side, close together, read as one
    /// paragraph: a person's turn, not the chunk boundaries inside it.
    public static func paragraphs(_ lines: [MeetingLine]) -> [MeetingLine] {
        var result: [MeetingLine] = []
        for line in lines {
            if let last = result.last, last.speaker == line.speaker,
               line.start - last.end < 8 {
                result[result.count - 1].text += " " + line.text
                result[result.count - 1].end = max(last.end, line.end)
            } else {
                result.append(line)
            }
        }
        return result
    }
}
