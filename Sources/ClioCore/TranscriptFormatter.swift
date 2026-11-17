import Foundation

/// The post-processing between "Whisper said this" and "this gets pasted" (§5.6).
///
/// Pure and free of AppKit so it can be tested directly.
public enum TranscriptFormatter {

    public static func format(_ text: String, settings: Settings) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        result = applyReplacements(result, settings.wordReplacements)

        if settings.trimTrailingPunctuation {
            while let last = result.last, last == "." || last == "," {
                result.removeLast()
            }
        }

        if settings.capitalizeFirstLetter, let first = result.first {
            result.replaceSubrange(result.startIndex...result.startIndex,
                                   with: String(first).uppercased())
        }

        return result
    }

    /// Whole-word, case-insensitive. Substring replacement would turn a rule
    /// like "it" → "IT" into a mess inside words such as "with".
    static func applyReplacements(_ text: String,
                                  _ replacements: [WordReplacement]) -> String {
        var result = text
        for rule in replacements {
            let find = rule.find.trimmingCharacters(in: .whitespaces)
            guard !find.isEmpty else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: find))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive])
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replace))
        }
        return result
    }

    /// Custom vocabulary becomes Whisper's `initialPrompt` — the cheapest way
    /// to make it spell names and jargon correctly (§5.4).
    public static func initialPrompt(from vocabulary: [String]) -> String? {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }

    /// Whisper reads about 224 tokens of prompt and no more. At four
    /// characters a token that is some 900 characters; this leaves room.
    static let vocabularyLimit = 600

    /// The vocabulary for one meeting: the user's own words, then the people
    /// invited, then the words of the event's title that look like names —
    /// the ones Whisper is most likely to spell wrong and the summary most
    /// needs right. For that meeting only; nothing is saved.
    ///
    /// The user's words come first because the list is cut at
    /// `vocabularyLimit`, and what they wrote down by hand is what they
    /// have already seen go wrong.
    public static func meetingVocabulary(user: [String], title: String?,
                                         attendees: [MeetingAttendee]) -> [String] {
        var candidates = user
        for attendee in attendees where !attendee.declined {
            // A calendar with no name for someone gives their address.
            if !attendee.name.contains("@") { candidates.append(attendee.name) }
        }
        if let title { candidates += nameLikeWords(in: title) }

        var terms: [String] = []
        var seen = Set<String>()
        var used = 0
        for candidate in candidates {
            let term = candidate.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            guard used + term.count + 2 <= vocabularyLimit else { break }
            terms.append(term)
            used += term.count + 2
        }
        return terms
    }

    /// The words of a title worth telling Whisper about: any with a capital
    /// or a digit in it — "Kiln", "OKRs", "Q3" — except a first word that
    /// is capitalised only for being first. A title in Title Case gives
    /// ordinary words too; they cost room and nothing else.
    static func nameLikeWords(in title: String) -> [String] {
        let words = title
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") })
            .map(String.init)
        var result: [String] = []
        for (index, word) in words.enumerated() where word.count > 1 {
            let marked = word.dropFirst().contains { $0.isUppercase || $0.isNumber }
            let capital = word.first.map { $0.isUppercase || $0.isNumber } ?? false
            if marked || (capital && index > 0) { result.append(word) }
        }
        return result
    }
}
