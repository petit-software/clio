import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A language model that can answer one prompt, for the summarizer.
///
/// Two of them: the model built into macOS (`SystemSummaryModel`) and a
/// downloaded GGUF run by llama.cpp (`LocalSummaryModel`). The summarizer
/// does not care which; it only needs to know how much it may send at once.
public protocol SummaryLanguageModel: Sendable {
    /// Characters of transcript per request, leaving room for the
    /// instructions and the answer.
    var pieceLimit: Int { get }
    /// One answer to one prompt. Nothing carries over between calls.
    func respond(instructions: String, prompt: String) async throws -> String
}

/// A summary of a meeting, written by a language model on this Mac.
///
/// By default that is Apple's on-device model: nothing to fetch, nothing
/// leaves the Mac, and on a Mac without Apple Intelligence the meeting simply
/// has no summary. Its context is about four thousand tokens, so a long
/// transcript is summarised a piece at a time and the pieces combined — with
/// the user's own notes, which say what mattered, given the final word. A
/// downloaded model holds the whole transcript of most meetings, so it
/// usually writes the summary from all of it in one go.
public enum MeetingSummarizer {

    /// Whether this Mac has the built-in model, right now.
    public static var isAvailable: Bool { SystemSummaryModel.isAvailable }

    /// The built-in model, where there is one.
    public static var system: (any SummaryLanguageModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            return SystemSummaryModel()
        }
        #endif
        return nil
    }

    /// The built-in model's piece: about 1,500 tokens.
    static let pieceLimit = 5_000

    static let pieceInstructions = """
        You summarize part of a meeting transcript. Lines are marked "Me" (the \
        person taking notes) or "Others" (everyone else on the call). Write \
        short bullet points of what was said: facts, decisions, numbers, names, \
        dates, and anything someone agreed to do. Leave out greetings and small \
        talk. Use only what is in the transcript.
        """

    public static let finalInstructions = """
        You write meeting notes. You are given either a transcript or bullet \
        points from one, and possibly the notes the person wrote during the \
        meeting. Their notes show what mattered most: cover those topics first \
        and fill them in from the transcript.

        Format, in Markdown:
        - A "### " heading per topic, named after what was actually discussed \
        (never "Discussion" or "Key points").
        - Short factual bullets under each heading.
        - A final "### Next steps" heading with "- [ ] task — owner" items, if \
        anyone agreed to do anything. Leave it out if not.
        No introduction, no conclusion, nothing that was not said.
        """

    /// With the built-in model. Nil where there is none.
    public static func summarize(_ record: MeetingRecord) async -> String? {
        guard let system else { return nil }
        return await summarize(record, with: system)
    }

    /// The instructions for the last request: the user's own, if they
    /// wrote any, else `finalInstructions`.
    static func instructions(custom: String?) -> String {
        let custom = (custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? finalInstructions : custom
    }

    /// With `model`. Nil when it had nothing to say, or failed throughout.
    /// `instructions` replaces Clio's own for the summary itself; the
    /// bullets a long transcript is first reduced to are always Clio's.
    public static func summarize(_ record: MeetingRecord,
                                 with model: any SummaryLanguageModel,
                                 instructions: String? = nil) async -> String? {
        let limit = max(1_000, model.pieceLimit)
        var material = record.transcriptText
        var label = "Transcript"
        // Map, then reduce again if the bullets are still too long.
        for _ in 0..<3 where material.count > limit {
            var bullets: [String] = []
            for piece in pieces(of: material, limit: limit) {
                if Task.isCancelled { return nil }
                if let answer = await respond(model, instructions: pieceInstructions, prompt: piece) {
                    bullets.append(answer)
                }
            }
            guard !bullets.isEmpty else { return nil }
            material = bullets.joined(separator: "\n")
            label = "Bullet points from the transcript"
        }
        if Task.isCancelled { return nil }
        let prompt = finalPrompt(about: details(of: record), notes: record.notes,
                                 material: material, label: label, limit: limit)
        return await respond(model, instructions: Self.instructions(custom: instructions),
                             prompt: prompt)
    }

    // MARK: A title

    static let titleInstructions = """
        You name meetings. Given the notes of one, answer with a title for it: \
        at most six words, what it was about, in the language of the notes. \
        No quotation marks, no full stop, nothing but the title.
        """

    /// A title for a meeting that has none of its own, from its summary —
    /// short enough for any model, and already what the meeting was about.
    /// Nil when the model gave nothing usable.
    public static func title(forSummary summary: String,
                             with model: any SummaryLanguageModel) async -> String? {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let prompt = String(summary.prefix(min(3_000, max(1_000, model.pieceLimit))))
        guard let answer = await respond(model, instructions: titleInstructions, prompt: prompt)
        else { return nil }
        return cleanTitle(answer)
    }

    /// The first line of the answer as a title: Markdown marks, quotes and a
    /// closing full stop off, and nothing if what is left is no title — too
    /// long to be one, or empty.
    static func cleanTitle(_ answer: String) -> String? {
        guard var line = answer.split(whereSeparator: \.isNewline).first.map(String.init)
        else { return nil }
        if line.lowercased().hasPrefix("title:") { line.removeFirst("title:".count) }
        let marks = CharacterSet(charactersIn: "#*_`\"'“”‘’ ").union(.whitespaces)
        line = line.trimmingCharacters(in: marks)
        while line.hasSuffix(".") { line.removeLast() }
        line = line.trimmingCharacters(in: marks)
        guard !line.isEmpty, line.count <= 80 else { return nil }
        return line
    }

    /// How much room the attendees may take. A company-wide invitation
    /// lists hundreds, and the transcript is what the summary is of.
    static let attendeesLimit = 400

    /// Said after the list of those invited. The list is for spelling a
    /// name the transcript says; it is not who is speaking.
    static let attribution = "The list is only for spelling names. The transcript does not "
        + "say which of them is speaking, or who came: name a person only where the "
        + "transcript itself names them."

    /// What the meeting was and who was invited, to lead the last prompt:
    /// the transcript only says "Me" and "Others", and a name said aloud
    /// means more to the model once it has seen the list. Those who declined
    /// are left out; they were not there to be quoted.
    static func details(of record: MeetingRecord) -> String {
        var lines = ["Meeting: \(record.title)",
                     "Date: \(record.startDate.formatted(date: .abbreviated, time: .shortened))"]
        var names: [String] = []
        var used = 0
        let present = record.attendees.filter { !$0.declined && !$0.name.isEmpty }
        for attendee in present {
            guard used + attendee.name.count + 2 <= attendeesLimit else { break }
            names.append(attendee.name)
            used += attendee.name.count + 2
        }
        if !names.isEmpty {
            let more = present.count - names.count
            lines.append("Invited: " + names.joined(separator: ", ")
                         + (more > 0 ? ", and \(more) more" : ""))
            // Without this the model works out who "Others" must be by
            // elimination and writes it down as fact: two invited, one
            // addressed by name, so the other one "will write the release
            // notes" (seen on Qwen3 4B, SummaryModelIntegration).
            lines.append(attribution)
        }
        return lines.joined(separator: "\n")
    }

    /// The least of the user's notes that goes in, whatever the model: they
    /// are the guide — what mattered — so they lead the prompt, but long
    /// ones are cut. Written out in full they pushed the prompt past a small
    /// model's context, and the summary was dropped without a word on
    /// exactly the meetings where the user had written most.
    static let notesLimit = 2_000

    /// How much of the notes a model with `limit` characters of room is
    /// given: a fifth of it, and never under `notesLimit`. Apple's model
    /// gets 2,000 characters; a downloaded one that holds an hour of
    /// meeting gets pages of them.
    static func notesLimit(for limit: Int) -> Int {
        max(notesLimit, limit / 5)
    }

    /// What heads the notes in the prompt. It says what they are and what
    /// to do with them, here and not only in the instructions — which the
    /// user may have replaced with their own, and theirs may not mention
    /// notes at all.
    static let notesHeading = "Notes written during the meeting, by the person this summary "
        + "is for. They are what mattered to them: cover every point in them, filled in "
        + "from what was said."

    /// The last prompt: the notes, capped, then the material, capped — so it
    /// always fits, however much was written or said. Notes beyond the
    /// least every model gets take their room from the material.
    static func finalPrompt(about details: String = "", notes: String, material: String,
                            label: String, limit: Int = pieceLimit) -> String {
        // As words: the times lines were written at are for the page.
        let notes = MarkdownSyntax.withoutTimeMarks(notes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var block = details.isEmpty ? "" : details + "\n\n"
        var room = limit
        if !notes.isEmpty {
            let most = notesLimit(for: limit)
            let kept = notes.count > most ? String(notes.prefix(most)) + "…" : notes
            block += "\(notesHeading)\n\(kept)\n\n"
            room -= max(0, kept.count - notesLimit)
        }
        return "\(block)\(label):\n\(String(material.prefix(room)))"
    }

    /// Splits text into pieces at line breaks, none over `limit`.
    static func pieces(of text: String, limit: Int = pieceLimit) -> [String] {
        var pieces: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line.prefix(limit))
            if !current.isEmpty, current.count + line.count + 1 > limit {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func respond(_ model: any SummaryLanguageModel,
                                instructions: String, prompt: String) async -> String? {
        do {
            let answer = clean(try await model.respond(instructions: instructions, prompt: prompt))
            return answer.isEmpty ? nil : answer
        } catch {
            return nil
        }
    }

    /// The answer as notes: a model's thinking, where it has a mode for it,
    /// is cut out, and a Markdown fence around the whole answer is opened.
    static func clean(_ answer: String) -> String {
        var text = answer
        while let open = text.range(of: "<think>") {
            guard let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound...)
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            lines.removeLast()
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

/// The model built into macOS 26, through FoundationModels.
public struct SystemSummaryModel: SummaryLanguageModel {
    public var pieceLimit: Int { MeetingSummarizer.pieceLimit }

    public init() {}

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // A session per request: nothing carries over to fill the context.
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw SummaryError.unavailable
    }
}

public enum SummaryError: LocalizedError {
    case unavailable
    case modelFailedToLoad(String)
    case promptTooLong
    case generationFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "No model is available to write a summary."
        case .modelFailedToLoad(let name): return "The model \(name) could not be loaded."
        case .promptTooLong: return "The transcript is too long for the model's context."
        case .generationFailed: return "The model stopped before finishing."
        }
    }
}
