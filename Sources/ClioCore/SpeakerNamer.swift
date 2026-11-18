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
        If a section "Voices heard before" is given, it compares each \
        speaker's voice with named speakers of earlier calls. It is separate \
        evidence from what is said: when the two agree, that is strong; a \
        voice that is "probably" someone's may be named so when nothing said \
        contradicts it; a voice only "a little like" someone's needs the \
        conversation to agree.
        When a name you found belongs to someone invited, write it as the list \
        has it, in full. A name that is only talked about ("I spoke to Jeff \
        yesterday") names nobody on the call. "Me" is never one of the numbered \
        speakers: when the name of "Me" is given, no numbered speaker has it, \
        and someone who says that name is talking to "Me", not to another \
        speaker. If you cannot tell who a speaker is with confidence, leave \
        them out.

        Answer with one line for each speaker you identified, in the form
        number | name
        and nothing else: no introduction, no explanation. If you identified \
        none, answer: none
        """

    /// The names a model found, by voice, for the voices that have none the
    /// user gave. Empty when there are no voices to name, or it found none.
    ///
    /// `matches` is what the voices themselves say — which earlier
    /// meetings' voices each resembles — for the model to weigh against
    /// the conversation.
    public static func names(for record: MeetingRecord,
                             with model: any SummaryLanguageModel,
                             matches: [Int: VoiceMatch] = [:]) async -> [Int: String] {
        let open = record.voiceNumbers.filter { record.voices[$0]?.confirmed != true }
        guard !open.isEmpty else { return [:] }
        let answer: String
        do {
            answer = try await model.respond(instructions: instructions,
                                             prompt: prompt(for: record, limit: model.pieceLimit,
                                                            matches: matches.filter { open.contains($0.key) }))
        } catch {
            return [:]
        }
        return settle(parse(MeetingSummarizer.clean(answer), voices: Set(open)), for: record)
    }

    /// A model's guesses, held to the invitation (`SpeakerRoster.settle`):
    /// never the name of whoever is recording, nobody uninvited while
    /// there are no more voices than people invited, and the last voice
    /// given to the last person. With no guesses at all it is that last
    /// rule alone, which needs no model.
    public static func settle(_ guesses: [Int: String], for record: MeetingRecord) -> [Int: String] {
        var known: [Int: String] = [:]
        for voice in record.voiceNumbers {
            if let named = record.voices[voice], named.confirmed { known[voice] = named.name }
        }
        return SpeakerRoster(attendees: record.attendees)
            .settle(guesses, known: known, voices: record.voiceNumbers)
    }

    /// Those invited, then the transcript with the voices as numbers —
    /// whatever names are guessed already are left out of it, so a wrong
    /// guess is not read back as evidence. Cut to `limit`: names are said
    /// at the start of a call far more often than at the end.
    static func prompt(for record: MeetingRecord, limit: Int,
                       matches: [Int: VoiceMatch] = [:]) -> String {
        var numbered = record
        for voice in record.voiceNumbers where record.voices[voice]?.confirmed != true {
            numbered.name(voice: voice, as: "", confirmed: true)
        }
        var parts: [String] = []
        // Those invited, less whoever is recording, who is said apart: in
        // one list, "Bart" is a name for a voice like any other.
        let roster = SpeakerRoster(attendees: record.attendees)
        if let me = roster.me { parts.append("\"Me\" is: \(me)") }
        if !roster.others.isEmpty {
            parts.append("Invited: " + String(roster.others.joined(separator: ", ").prefix(MeetingSummarizer.attendeesLimit)))
        }
        if !matches.isEmpty {
            let lines = matches.keys.sorted().map { voice in
                "\(MeetingRecord.placeholder(voice)): " + describe(matches[voice]!)
            }
            parts.append("Voices heard before:\n" + lines.joined(separator: "\n"))
        }
        parts.append("Transcript:\n" + String(numbered.transcriptText.prefix(max(1_000, limit))))
        return parts.joined(separator: "\n\n")
    }

    /// A match as a sentence the model can weigh.
    static func describe(_ match: VoiceMatch) -> String {
        let meetings = "\(match.meetings) earlier \(match.meetings == 1 ? "call" : "calls")"
        switch match.level {
        case .high:
            return "the voice is almost certainly \(match.name)'s (\(meetings))."
        case .medium:
            return "the voice is probably \(match.name)'s (\(meetings))."
        case .low:
            return "the voice is a little like \(match.name)'s; not enough on its own."
        case .ambiguous:
            return "the voice is like those of " + match.names.joined(separator: " and ")
                + "; the conversation has to say which."
        }
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
