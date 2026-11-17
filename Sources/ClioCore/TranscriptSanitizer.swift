import Foundation

/// What Whisper makes up at the end of a recording, taken out.
///
/// Given audio that stops, Whisper sometimes keeps going: a segment
/// timestamped after the last sample, or one stray word — "you", "Thanks." —
/// that it was not at all sure of. Both are inventions, and in a meeting
/// each 25-second chunk has an end for them to happen at.
///
/// Pure, on values: the engine turns WhisperKit's segments into `Segment`
/// and back into text.
public enum TranscriptSanitizer {

    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        /// The mean probability of the segment's text tokens, 0…1. Nil when
        /// the engine did not say — and then nothing is dropped on it.
        public var probability: Double?

        public init(start: Double, end: Double, text: String, probability: Double? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.probability = probability
        }
    }

    /// Under this, a last segment of one word is taken for an invention.
    /// Real speech, even mumbled, sits well above it.
    static let trailingWordProbability = 0.3

    /// `segments` without what cannot have been said in `audioDuration`
    /// seconds of audio:
    /// 1. a segment that starts at or after the end is dropped;
    /// 2. one that runs past the end is cut to it;
    /// 3. a last segment of a single word the model was unsure of is dropped.
    public static func sanitize(_ segments: [Segment], audioDuration: Double) -> [Segment] {
        var kept: [Segment] = []
        for var segment in segments {
            if audioDuration > 0 {
                guard segment.start < audioDuration else { continue }
                segment.end = min(segment.end, audioDuration)
            }
            kept.append(segment)
        }
        if let last = kept.last, let probability = last.probability,
           probability < trailingWordProbability, wordCount(last.text) == 1 {
            kept.removeLast()
        }
        return kept
    }

    /// The segments as one line of text, Whisper's `<|…|>` tokens removed.
    public static func text(of segments: [Segment]) -> String {
        segments
            .map { plain($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCount(_ text: String) -> Int {
        plain(text).split(whereSeparator: { $0.isWhitespace }).count
    }
}
