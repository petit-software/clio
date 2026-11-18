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

    /// Where in a recording there is sound, in 20 ms frames: what a segment
    /// is checked against, to see whether anything was said where the model
    /// says something was.
    public struct Sound: Sendable, Equatable {
        static let frameSeconds = 0.02
        /// A frame counts as sound at a twenty-fifth of the loudest frame's
        /// level. Relative, so a quiet recording is not all silence and a
        /// loud one is not all sound; and with a floor, so digital silence
        /// with one stray sample is not "sound" throughout.
        static let relativeLevel: Float = 0.04
        static let floor: Float = 0.0005

        var frames: [Bool]

        public init(samples: [Float], sampleRate: Double) {
            let size = max(1, Int(sampleRate * Self.frameSeconds))
            var levels: [Float] = []
            levels.reserveCapacity(samples.count / size + 1)
            var index = 0
            while index < samples.count {
                let end = min(samples.count, index + size)
                var sum: Float = 0
                for sample in samples[index..<end] { sum += sample * sample }
                levels.append((sum / Float(end - index)).squareRoot())
                index = end
            }
            let threshold = max(Self.floor, (levels.max() ?? 0) * Self.relativeLevel)
            frames = levels.map { $0 > threshold }
        }

        init(frames: [Bool]) { self.frames = frames }

        /// Seconds of sound between `start` and `end`.
        func seconds(from start: Double, to end: Double) -> Double {
            let first = max(0, Int(start / Self.frameSeconds))
            let last = min(frames.count, Int((end / Self.frameSeconds).rounded(.up)))
            guard first < last else { return 0 }
            return Double(frames[first..<last].filter { $0 }.count) * Self.frameSeconds
        }
    }

    /// A segment with less sound in it than this, and less than
    /// `leastSoundShare` of its length, was not said: there is nothing
    /// there to have been heard. A real "Yes." is a third of a second of
    /// voice in a segment not much longer.
    static let leastSoundSeconds = 0.25
    static let leastSoundShare = 0.1

    /// `segments` without what cannot have been said in `audioDuration`
    /// seconds of audio:
    /// 1. a segment that starts at or after the end is dropped;
    /// 2. one that runs past the end is cut to it;
    /// 3. a last segment of a single word the model was unsure of is dropped.
    /// 4. with `sound`: a segment over a stretch with next to no sound in
    ///    it is dropped — the confident sentence Whisper writes into a
    ///    silence ("Thank you." at 0.80, after the speech had stopped).
    public static func sanitize(_ segments: [Segment], audioDuration: Double,
                                sound: Sound? = nil) -> [Segment] {
        var kept: [Segment] = []
        for var segment in segments {
            if audioDuration > 0 {
                guard segment.start < audioDuration else { continue }
                segment.end = min(segment.end, audioDuration)
            }
            if let sound, segment.end > segment.start {
                let heard = sound.seconds(from: segment.start, to: segment.end)
                if heard < leastSoundSeconds, heard < (segment.end - segment.start) * leastSoundShare {
                    continue
                }
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
