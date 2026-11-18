import Foundation

/// A link into Clio: a meeting, a search, or taking notes.
///
///     clio://meeting?id=2026-11-18%2009.00%20Weekly%20sync
///     clio://search?q=pricing
///     clio://notes            (start taking notes)
///
/// What other apps are handed when they ask about a meeting, and what a
/// note elsewhere can point back with.
public enum AppLink: Equatable, Sendable {
    /// By the meeting's id: its file's name, without ".md".
    case meeting(id: String)
    case search(query: String)
    case takeNotes

    public static let scheme = "clio"

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        switch (components.host ?? "").lowercased() {
        case "meeting":
            guard let id = value("id"), !id.isEmpty else { return nil }
            self = .meeting(id: id)
        case "search":
            self = .search(query: value("q") ?? "")
        case "notes":
            self = .takeNotes
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .meeting(let id):
            components.host = "meeting"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .takeNotes:
            components.host = "notes"
        }
        return components.url!
    }

    /// A meeting's id: its file's name without the extension. It changes
    /// when the meeting is renamed, as the file does.
    public static func id(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    /// The file an id names, in `folder`.
    public static func file(for id: String, in folder: URL) -> URL? {
        // The name only: an id is never a path out of the folder.
        let name = (id as NSString).lastPathComponent
        guard !name.isEmpty, name == id else { return nil }
        let url = folder.appendingPathComponent(name + ".md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// What other apps may ask of the meetings, through the MCP server: find
/// them, read one, read its transcript. Reading only — nothing here writes,
/// deletes, records or changes a setting.
public struct MeetingTools: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public struct ToolError: Error, Equatable {
        public var message: String
    }

    /// The tools as MCP lists them.
    public static var definitions: [[String: Any]] { [
        [
            "name": "clio_query_meetings",
            "description": "Find meetings recorded or noted in Clio on this Mac. Returns the newest first, "
                + "each with its id, title, start time, who was invited and a one-line preview. "
                + "All arguments are optional; with none, the most recent meetings are returned.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Words that must all appear in the meeting's title, notes, summary or transcript."],
                    "person": ["type": "string",
                               "description": "A name or email of someone invited, or a named speaker."],
                    "from": ["type": "string",
                             "description": "Earliest start, as YYYY-MM-DD or an ISO 8601 date-time."],
                    "to": ["type": "string",
                           "description": "Latest start, as YYYY-MM-DD (the whole day) or an ISO 8601 date-time."],
                    "limit": ["type": "integer", "description": "The most to return. 20 if not given; at most 100."],
                ],
            ],
        ],
        [
            "name": "clio_get_meeting",
            "description": "One meeting by id: its title, time, people, the notes written by hand, and the summary. "
                + "The transcript is not included; ask for it with clio_get_transcript.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The id from clio_query_meetings."]],
                "required": ["id"],
            ],
        ],
        [
            "name": "clio_get_transcript",
            "description": "The transcript of one meeting by id, as timed lines headed by who spoke: "
                + "\"Me\" is the person whose Mac this is; the others are named, or \"Speaker 1\", or \"Others\".",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The id from clio_query_meetings."]],
                "required": ["id"],
            ],
        ],
    ] }

    /// Runs a tool and returns what it says, as text.
    public func call(_ name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "clio_query_meetings": return try query(arguments)
        case "clio_get_meeting": return try meeting(arguments)
        case "clio_get_transcript": return try transcript(arguments)
        default: throw ToolError(message: "Clio has no tool named \(name).")
        }
    }

    // MARK: The tools

    static func date(_ text: String, endOfDay: Bool) -> Date? {
        if let date = MeetingMarkdown.iso.date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        guard let start = day.date(from: text) else { return nil }
        return endOfDay ? start.addingTimeInterval(86_400 - 1) : start
    }

    private func query(_ arguments: [String: Any]) throws -> String {
        var files = MeetingLibrary.scan(folder)
        if let words = (arguments["query"] as? String)?.lowercased().split(separator: " ").map(String.init),
           !words.isEmpty {
            files = files.filter { file in words.allSatisfy { file.searchText.contains($0) } }
        }
        if let person = (arguments["person"] as? String)?.lowercased(), !person.isEmpty {
            files = files.filter { file in
                file.attendees.contains {
                    $0.name.lowercased().contains(person) || ($0.email ?? "").lowercased().contains(person)
                } || file.searchText.contains("speaker-") && file.searchText.contains(person)
            }
        }
        if let text = arguments["from"] as? String {
            guard let from = Self.date(text, endOfDay: false) else {
                throw ToolError(message: "\"from\" is not a date: \(text). Use YYYY-MM-DD.")
            }
            files = files.filter { $0.start >= from }
        }
        if let text = arguments["to"] as? String {
            guard let to = Self.date(text, endOfDay: true) else {
                throw ToolError(message: "\"to\" is not a date: \(text). Use YYYY-MM-DD.")
            }
            files = files.filter { $0.start <= to }
        }
        let limit = min(100, max(1, (arguments["limit"] as? Int) ?? 20))
        let found = files.count
        let meetings: [[String: Any]] = files.prefix(limit).map { file in
            var entry: [String: Any] = [
                "id": AppLink.id(of: file.url),
                "title": file.title,
                "start": MeetingMarkdown.iso.string(from: file.start),
                "preview": file.preview,
                "link": AppLink.meeting(id: AppLink.id(of: file.url)).url.absoluteString,
            ]
            if let end = file.end { entry["end"] = MeetingMarkdown.iso.string(from: end) }
            if !file.attendees.isEmpty { entry["attendees"] = file.attendees.map(\.name) }
            return entry
        }
        return Self.json(["found": found, "returned": meetings.count, "meetings": meetings])
    }

    private func record(_ arguments: [String: Any]) throws -> (MeetingRecord, URL) {
        guard let id = arguments["id"] as? String, !id.isEmpty else {
            throw ToolError(message: "An id is needed: one from clio_query_meetings.")
        }
        guard let url = AppLink.file(for: id, in: folder),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let record = MeetingMarkdown.parse(text) else {
            throw ToolError(message: "No meeting has the id \(id). It may have been renamed; ask clio_query_meetings again.")
        }
        return (record, url)
    }

    private func meeting(_ arguments: [String: Any]) throws -> String {
        let (record, url) = try record(arguments)
        var result: [String: Any] = [
            "id": AppLink.id(of: url),
            "title": record.title,
            "start": MeetingMarkdown.iso.string(from: record.startDate),
            "notes": MarkdownSyntax.withoutTimeMarks(record.notes),
            "has_transcript": !record.lines.isEmpty,
            "link": AppLink.meeting(id: AppLink.id(of: url)).url.absoluteString,
        ]
        if let end = record.endDate { result["end"] = MeetingMarkdown.iso.string(from: end) }
        if !record.attendees.isEmpty {
            result["attendees"] = record.attendees.map { attendee -> [String: Any] in
                var person: [String: Any] = ["name": attendee.name]
                if let email = attendee.email { person["email"] = email }
                if attendee.declined { person["declined"] = true }
                return person
            }
        }
        if let summary = record.summary { result["summary"] = summary }
        let speakers = record.voiceNumbers.map { record.label(for: MeetingLine(
            speaker: .others, start: 0, end: 0, text: "", voice: $0)) }
        if !speakers.isEmpty { result["speakers"] = speakers }
        return Self.json(result)
    }

    private func transcript(_ arguments: [String: Any]) throws -> String {
        let (record, _) = try record(arguments)
        guard !record.lines.isEmpty else {
            return "This meeting has no transcript: it was written by hand, or nothing was said."
        }
        return "# \(record.title)\n\n" + record.transcriptText
    }

    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
