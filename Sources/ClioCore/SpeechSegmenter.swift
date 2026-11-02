import Foundation

/// A stretch of speech from one side of a meeting, ready to transcribe.
public struct SpeechChunk: Sendable, Equatable {
    public var samples: [Float]
    /// Seconds from the start of the meeting to the first sample.
    public var start: TimeInterval

    public var duration: TimeInterval { Double(samples.count) / AudioRecorder.sampleRate }
    public var end: TimeInterval { start + duration }

    public init(samples: [Float], start: TimeInterval) {
        self.samples = samples
        self.start = start
    }
}

/// Cuts a live stream of 16 kHz audio into chunks at the pauses in speech.
///
/// Not every thirty seconds. A cut on a timer lands mid-word as often as
/// not, and the word is lost or garbled on both sides of it; and a chunk's
/// only timestamp is then the timer's, so two people's lines in the same
/// thirty seconds come out as two blocks rather than a conversation. Here a
/// chunk ends where someone stopped talking, carries the time its first
/// sample was spoken, and is short enough — 25 seconds at most — to be one
/// of Whisper's windows, which is the fastest thing it can be given.
///
/// Silence between chunks is dropped as it arrives, so the buffer only ever
/// holds the speech in progress.
public struct SpeechSegmenter: Sendable {
    public struct Configuration: Sendable {
        /// Shortest chunk worth cutting at an ordinary pause.
        public var minimumSeconds: Double = 4
        /// A chunk is cut here whatever is going on, at its quietest moment.
        public var maximumSeconds: Double = 25
        /// A pause this long ends a chunk that is at least `minimumSeconds`.
        public var pauseSeconds: Double = 0.6
        /// A pause this long ends a chunk of any length — a lone "yes".
        public var longPauseSeconds: Double = 1.5
        /// Silence kept either side of the speech, so soft consonants survive.
        public var marginSeconds: Double = 0.2
        /// RMS above which a frame counts as speech.
        public var threshold: Float

        public init(sensitivity: Double = 0.5) {
            threshold = VoiceActivityTrimmer.energyThreshold(for: sensitivity)
        }
    }

    public let configuration: Configuration

    private static let sampleRate = AudioRecorder.sampleRate
    /// 30 ms frames: short enough to find a gap between words.
    static let frameSamples = 480

    /// The chunk being built, and the absolute index of its first sample.
    private var buffer: [Float] = []
    private var bufferStart = 0
    /// The loudness of each whole frame in `buffer`.
    private var frameLevels: [Float] = []
    /// Samples not yet making up a whole frame.
    private var pending: [Float] = []
    private var hasSpeech = false
    private var trailingSilentFrames = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Adds samples and returns any chunks they completed.
    public mutating func append(_ samples: [Float]) -> [SpeechChunk] {
        pending.append(contentsOf: samples)
        var chunks: [SpeechChunk] = []
        let frame = Self.frameSamples
        var offset = 0
        while pending.count - offset >= frame {
            let slice = pending[offset..<offset + frame]
            offset += frame
            if let chunk = addFrame(slice) { chunks.append(chunk) }
        }
        pending.removeFirst(offset)
        return chunks
    }

    /// Time passed with no samples at all — the system audio tap delivers
    /// nothing while nothing plays. Ends any speech in progress, as a pause
    /// would, and moves the clock on so the next chunk starts when it was
    /// said. Costs no memory however long the gap: only enough silence to
    /// close the speech is fed through; the rest is skipped.
    public mutating func skip(_ sampleCount: Int) -> [SpeechChunk] {
        guard sampleCount > 0 else { return [] }
        let closing = Int((configuration.longPauseSeconds + 0.1) * Self.sampleRate)
        let fed = min(sampleCount, closing)
        let chunks = append([Float](repeating: 0, count: fed))
        let rest = sampleCount - fed
        if rest > 0 {
            // After a long pause nothing is in progress: what is buffered is
            // silence, and it is dropped along with the gap.
            bufferStart += buffer.count + pending.count + rest
            buffer = []
            frameLevels = []
            pending = []
            hasSpeech = false
            trailingSilentFrames = 0
        }
        return chunks
    }

    /// Whatever speech is left, at the end of the meeting.
    public mutating func finish() -> [SpeechChunk] {
        if !pending.isEmpty {
            buffer.append(contentsOf: pending)
            frameLevels.append(Self.rms(pending[...]))
            pending = []
        }
        // Recounted: the leftover samples may have changed what is trailing.
        trailingSilentFrames = frameLevels.reversed()
            .prefix { $0 <= configuration.threshold }.count
        guard hasSpeech || frameLevels.last.map({ $0 > configuration.threshold }) == true
        else { return [] }
        let speechEnd = frameLevels.count - trailingSilentFrames
        guard let chunk = cut(atFrame: min(frameLevels.count,
                                           speechEnd + frames(configuration.marginSeconds)))
        else { return [] }
        return [chunk]
    }

    // MARK: Frames

    private mutating func addFrame(_ frame: ArraySlice<Float>) -> SpeechChunk? {
        let level = Self.rms(frame)
        let voiced = level > configuration.threshold
        buffer.append(contentsOf: frame)
        frameLevels.append(level)

        if voiced {
            hasSpeech = true
            trailingSilentFrames = 0
        } else {
            trailingSilentFrames += 1
        }

        // Nothing said yet: keep only the margin's worth of lead-in.
        if !hasSpeech {
            let keep = frames(configuration.marginSeconds)
            if frameLevels.count > keep { drop(frames: frameLevels.count - keep) }
            return nil
        }

        let length = Double(buffer.count) / Self.sampleRate
        let pause = Double(trailingSilentFrames * Self.frameSamples) / Self.sampleRate

        if pause >= configuration.longPauseSeconds
            || (pause >= configuration.pauseSeconds && length >= configuration.minimumSeconds) {
            // End the chunk a margin after the speech stopped.
            let speechEnd = frameLevels.count - trailingSilentFrames
            return cut(atFrame: min(frameLevels.count, speechEnd + frames(configuration.marginSeconds)))
        }

        if length >= configuration.maximumSeconds {
            // Nobody has paused for long enough. Cut at the quietest frame
            // in the last few seconds, which is most likely between words.
            let search = frames(4)
            let from = max(frames(configuration.minimumSeconds), frameLevels.count - search)
            var quietest = frameLevels.count - 1
            for index in from..<frameLevels.count where frameLevels[index] < frameLevels[quietest] {
                quietest = index
            }
            return cut(atFrame: quietest + 1)
        }
        return nil
    }

    /// Emits the first `frameCount` frames as a chunk and keeps the rest as
    /// the start of the next one.
    private mutating func cut(atFrame frameCount: Int) -> SpeechChunk? {
        let sampleCount = min(buffer.count, frameCount * Self.frameSamples)
        guard sampleCount > 0 else { return nil }
        let chunk = SpeechChunk(samples: Array(buffer[0..<sampleCount]),
                                start: Double(bufferStart) / Self.sampleRate)
        buffer.removeFirst(sampleCount)
        frameLevels.removeFirst(min(frameCount, frameLevels.count))
        bufferStart += sampleCount
        // What is left over is speech only if any of it is loud enough.
        hasSpeech = frameLevels.contains { $0 > configuration.threshold }
        trailingSilentFrames = frameLevels.reversed()
            .prefix { $0 <= configuration.threshold }.count
        return chunk
    }

    private mutating func drop(frames count: Int) {
        let samples = min(buffer.count, count * Self.frameSamples)
        buffer.removeFirst(samples)
        frameLevels.removeFirst(min(count, frameLevels.count))
        bufferStart += samples
        trailingSilentFrames = min(trailingSilentFrames, frameLevels.count)
    }

    private func frames(_ seconds: Double) -> Int {
        Int((seconds * Self.sampleRate / Double(Self.frameSamples)).rounded(.up))
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for value in frame { sum += value * value }
        return (sum / Float(frame.count)).squareRoot()
    }
}
