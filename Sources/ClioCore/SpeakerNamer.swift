import Foundation

/// The names of the voices on a call, worked out from what was said.
///
/// Diarization gives "Speaker 1" and "Speaker 2"; who they are is in the
/// transcript, when it is anywhere: someone says their own name, or is
/// called by it. A language model reads for that. What it finds is a guess
/// — marked as one in the file, shown like any name, and replaced by
/// whatever the user types.
public enum SpeakerNamer {

    static let instructions = """
        You are given the transcript of a call. "Me" is the person who recorded \
        it. Everyone else is labelled Speaker 1, Speaker 2, and so on. Work out \
        the real name of each numbered speaker, using only evidence in the \
        transcript:
        - they say who they are ("Hi, I'm Jeff", "This is Ana");
        - someone speaks to them by name right before or right after they talk \
        ("Thanks, Jeff" names whoever just spoke; "Jeff, what do you think?" \
        names whoever answers).
        If a list of people invited is given, use it only to write a name you \
        found that way in full. Never guess. Never name a speaker because they \
        are the only person left over. A name that is only mentioned ("I \
        talked to Jeff yesterday") names nobody.

        Answer with one line for each speaker you are sure of, in the form
        number | name
        and nothing else. If you are sure of none, answer: none
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
