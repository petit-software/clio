import Foundation

/// The names of the voices on a call, worked out from what was said.
///
/// Diarization gives "Speaker 1" and "Speaker 2"; who they are is in the
/// transcript, when it is anywhere: someone says their own name, or is
/// called by it, or it follows from who was invited. A language model
/// reads for that, the way Biscotti's does. What it finds is a guess
/// — marked as one in the file, shown like any name, and replaced by
/// whatever the user types.
public enum SpeakerNamer {

    /// The rules Biscotti gives its model, in Clio's words: what is said in
    /// the conversation and who was invited are both evidence, and a
    /// speaker the model is not confident of is left out. The first
    /// version here allowed only a self-introduction or a name said right
    /// beside a turn, and forbade everything else; on a scripted call it
    /// named the one who said "this is Karen" and left the one asked
    /// "Daniel, do you want to start?" a number.
    static let instructions = """
        You are given the transcript of a call. "Me" is the person who recorded \
        it. Everyone else is labelled Speaker 1, Speaker 2, and so on. Match \
        each numbered speaker to a real person, using what is said in the \
        transcript and, if one is given, the list of people invited. For example:
        - "Hi, I'm Jeff" or "This is Ana from marketing": the one speaking is \
        Jeff, or Ana.
        - "Jeff, what do you think?" or "Do you want to start, Jeff?": whoever \
        answers next is Jeff.
        - "Thanks for that, Jeff": whoever spoke just before is Jeff.
        - If there is only one numbered speaker, a name "Me" calls them by is \
        their name.
        - Other clues in what people say about themselves and each other.
        When a name you found belongs to someone invited, write it as the list \
        has it, in full. A name that is only talked about ("I spoke to Jeff \
        yesterday") names nobody on the call. "Me" is never one of the numbered \
        speakers. If you cannot tell who a speaker is with confidence, leave \
        them out.

        Answer with one line for each speaker you identified, in the form
        number | name
        and nothing else: no introduction, no explanation. If you identified \
        none, answer: none
        """

    /// The names a model found, by voice, for the voices that have none the
    /// user gave. Empty when there are no voices to name, or it found none.
    public static func names(for record: MeetingRecord,
                             with model: any SummaryLanguageModel) async -> [Int: String] {
        let open = record.voiceNumbers.filter { record.voices[$0]?.confirmed != true }
        guard !open.isEmpty else { return [:] }
        let answer: String
        do {
            answer = try await model.respond(instructions: instructions,
                                             prompt: prompt(for: record, limit: model.pieceLimit))
        } catch {
            return [:]
        }
        return parse(MeetingSummarizer.clean(answer), voices: Set(open))
    }

    /// Those invited, then the transcript with the voices as numbers —
    /// whatever names are guessed already are left out of it, so a wrong
    /// guess is not read back as evidence. Cut to `limit`: names are said
    /// at the start of a call far more often than at the end.
    static func prompt(for record: MeetingRecord, limit: Int) -> String {
        var numbered = record
        for voice in record.voiceNumbers where record.voices[voice]?.confirmed != true {
            numbered.name(voice: voice, as: "", confirmed: true)
        }
        var parts: [String] = []
        let invited = record.attendees.filter { !$0.declined && !$0.name.isEmpty && !$0.name.contains("@") }
            .map(\.name)
        if !invited.isEmpty {
            parts.append("Invited: " + String(invited.joined(separator: ", ").prefix(MeetingSummarizer.attendeesLimit)))
        }
        parts.append("Transcript:\n" + String(numbered.transcriptText.prefix(max(1_000, limit))))
        return parts.joined(separator: "\n\n")
    }

    /// "2 | Ana Ruiz" → [2: "Ana Ruiz"]. Forgiving of "Speaker 2 | Ana" and
    /// of Markdown around either side; strict about everything else: a
    /// number that is no voice, a name that is no name, and one name given
    /// to two voices — which is wrong about at least one of them — are all
    /// left out.
    static func parse(_ answer: String, voices: Set<Int>) -> [Int: String] {
        var found: [Int: String] = [:]
        for line in answer.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let digits = parts[0].filter(\.isNumber)
            guard let voice = Int(digits), voices.contains(voice), found[voice] == nil else { continue }
            let name = MeetingRecord.cleanName(
                parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " `\"'“”").union(.whitespaces)))
            let lowered = name.lowercased()
            guard !name.isEmpty, name.count <= 40, name.contains(where: \.isLetter),
                  !["none", "unknown", "n/a", "?"].contains(lowered),
                  !lowered.hasPrefix("unknown"), !lowered.hasPrefix("not ") else { continue }
            found[voice] = name
        }
        var counts: [String: Int] = [:]
        for name in found.values { counts[name.lowercased(), default: 0] += 1 }
        return found.filter { counts[$0.value.lowercased()] == 1 }
    }
}
