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
}
