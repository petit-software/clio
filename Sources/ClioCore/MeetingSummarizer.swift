import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A summary of a meeting, written by the language model built into macOS.
///
/// Apple's on-device model, not one Clio downloads: nothing to fetch, nothing
/// leaves the Mac, and on a Mac without Apple Intelligence the meeting simply
/// has no summary. Its context is about four thousand tokens, so a long
/// transcript is summarised a piece at a time and the pieces combined — with
/// the user's own notes, which say what mattered, given the final word.
public enum MeetingSummarizer {

    /// Whether this Mac can write one right now.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Characters per piece: about 1,500 tokens, leaving room for the
    /// instructions and the answer.
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

    public static func summarize(_ record: MeetingRecord) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            return await summarizeWithSystemModel(record)
        }
        #endif
        return nil
    }

    /// How much of the user's notes goes in. They are the guide — what
    /// mattered — so they lead the prompt, but long ones are cut: written
    /// out in full they pushed the prompt past the model's context, and the
    /// summary was dropped without a word on exactly the meetings where the
    /// user had written most.
    static let notesLimit = 2_000

    /// The last prompt: the notes, capped, then the material, capped — so it
    /// always fits, however much was written or said.
    static func finalPrompt(notes: String, material: String, label: String) -> String {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var block = ""
        if !notes.isEmpty {
            let kept = notes.count > notesLimit ? String(notes.prefix(notesLimit)) + "…" : notes
            block = "Notes written during the meeting:\n\(kept)\n\n"
        }
        return "\(block)\(label):\n\(String(material.prefix(pieceLimit)))"
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

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func summarizeWithSystemModel(_ record: MeetingRecord) async -> String? {
        var material = record.transcriptText
        var label = "Transcript"
        // Map, then reduce again if the bullets are still too long.
        for _ in 0..<3 where material.count > pieceLimit {
            var bullets: [String] = []
            for piece in pieces(of: material) {
                if let answer = await respond(instructions: pieceInstructions, prompt: piece) {
                    bullets.append(answer)
                }
            }
            guard !bullets.isEmpty else { return nil }
            material = bullets.joined(separator: "\n")
            label = "Bullet points from the transcript"
        }

        let prompt = finalPrompt(notes: record.notes, material: material, label: label)
        return await respond(instructions: finalInstructions, prompt: prompt)
    }

    @available(macOS 26.0, *)
    private static func respond(instructions: String, prompt: String) async -> String? {
        // A session per request: nothing carries over to fill the context.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let answer = try await session.respond(to: prompt).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : answer
        } catch {
            return nil
        }
    }
    #endif
}
