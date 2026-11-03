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

    static let finalInstructions = """
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

    /// With `model`. Nil when it had nothing to say, or failed throughout.
    public static func summarize(_ record: MeetingRecord,
                                 with model: any SummaryLanguageModel) async -> String? {
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
        let prompt = finalPrompt(notes: record.notes, material: material, label: label, limit: limit)
        return await respond(model, instructions: finalInstructions, prompt: prompt)
    }

    /// How much of the user's notes goes in. They are the guide — what
    /// mattered — so they lead the prompt, but long ones are cut: written
    /// out in full they pushed the prompt past the model's context, and the
    /// summary was dropped without a word on exactly the meetings where the
    /// user had written most.
    static let notesLimit = 2_000

    /// The last prompt: the notes, capped, then the material, capped — so it
    /// always fits, however much was written or said.
    static func finalPrompt(notes: String, material: String, label: String,
                            limit: Int = pieceLimit) -> String {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var block = ""
        if !notes.isEmpty {
            let kept = notes.count > notesLimit ? String(notes.prefix(notesLimit)) + "…" : notes
            block = "Notes written during the meeting:\n\(kept)\n\n"
        }
        return "\(block)\(label):\n\(String(material.prefix(limit)))"
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
