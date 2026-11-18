import Foundation
import WhisperKit

/// The real engine (§5.4).
///
/// WhisperKit runs the encoder on the Apple Neural Engine, which is the reason
/// this app is native rather than a whisper.cpp wrapper.
///
/// Configured with `download: false` and an explicit `modelFolder`: models are
/// installed by our own ModelManager, and WhisperKit reaching for the network
/// on its own would quietly break the offline guarantee.
public actor WhisperKitEngine: TranscriptionEngine {

    public enum EngineError: LocalizedError {
        case notLoaded
        case modelFolderMissing(String)
        case emptyResult

        public var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "The transcription model is not loaded yet."
            case .modelFolderMissing(let path):
                return "The model folder is missing at \(path)."
            case .emptyResult:
                return "The model returned no text."
            }
        }
    }

    private var pipe: WhisperKit?
    private var loadedModelID: String?

    public init() {}

    public var isLoaded: Bool { pipe != nil }

    public var currentModelID: String? { loadedModelID }

    public func load(model: InstalledModel) async throws {
        // Loading the same model twice costs seconds for nothing; this is what
        // makes the load-on-hotkey-down warm-up worth doing.
        if loadedModelID == model.id, pipe != nil { return }

        guard FileManager.default.fileExists(atPath: model.url.path) else {
            throw EngineError.modelFolderMissing(model.url.path)
        }

        if pipe != nil { await unload() }

        let config = WhisperKitConfig(
            modelFolder: model.url.path,
            tokenizerFolder: ModelManager.tokenizerDirectory(for: model),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false)

        pipe = try await WhisperKit(config)
        loadedModelID = model.id
    }

    public func unload() async {
        await pipe?.unloadModels()
        pipe = nil
        loadedModelID = nil
    }

    public func transcribe(samples: [Float],
                           options: TranscribeOptions) async throws -> Transcript {
        let decoded = try await decode(samples: samples, options: options)
        var text = decoded.text

        // What Whisper invents at the end of the audio comes out. The text is
        // rebuilt from the segments only when one was dropped; otherwise it
        // is WhisperKit's own, untouched.
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let kept = TranscriptSanitizer.sanitize(
            decoded.segments, audioDuration: duration,
            sound: TranscriptSanitizer.Sound(samples: samples, sampleRate: AudioRecorder.sampleRate))
        if kept.count < decoded.segments.count {
            text = TranscriptSanitizer.text(of: kept)
        }

        // Silence is a legitimate outcome, not an error — the coordinator turns
        // an empty transcript into "nothing was transcribed".
        return Transcript(text: text, language: decoded.language, duration: duration)
    }

    /// What the model said, before anything is taken out of it.
    struct Decoded {
        var text: String
        var language: String?
        var segments: [TranscriptSanitizer.Segment]
    }

    func decode(samples: [Float], options: TranscribeOptions) async throws -> Decoded {
        guard let pipe else { throw EngineError.notLoaded }

        var decoding = DecodingOptions()
        decoding.task = options.translateToEnglish ? .translate : .transcribe
        decoding.language = options.language
        decoding.detectLanguage = options.language == nil
        // Dictation goes straight into a text field, so the special tokens
        // Whisper emits are noise. skipSpecialTokens strips them from the text.
        decoding.skipSpecialTokens = true

        // withoutTimestamps stays FALSE, deliberately. Whisper transcribes in
        // 30-second windows and uses the timestamp tokens it emits to work out
        // where the next window resumes; suppressing them leaves it unable to
        // advance, so anything past the first window is silently dropped.
        //
        // This shipped as true, on the reasoning that timestamps were noise in
        // a text field. They are — but skipSpecialTokens already removes them
        // from the output, so it bought nothing and cost everything after 30
        // seconds. Measured on one 60s recording: 154 characters with it on,
        // 993 with it off. See the LongAudio test.
        decoding.withoutTimestamps = false

        if let prompt = options.initialPrompt,
           let tokenizer = pipe.tokenizer {
            // Leading space because Whisper's vocabulary is space-prefixed.
            let tokens = tokenizer.encode(text: " " + prompt)
            if !tokens.isEmpty {
                decoding.promptTokens = tokens
                decoding.usePrefillPrompt = true
            }
        }

        let results = try await pipe.transcribe(audioArray: samples,
                                                decodeOptions: decoding)

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let special = pipe.tokenizer?.specialTokens.specialTokenBegin
        return Decoded(
            text: text,
            language: results.first?.language ?? options.language,
            segments: results.flatMap(\.segments).map {
                Self.segment($0, specialTokenBegin: special)
            })
    }

    /// A WhisperKit segment as the sanitizer wants it. The probability is
    /// the mean over the segment's text tokens — from the log-probabilities
    /// every decode carries, so word timestamps (and their second pass) are
    /// not needed for it. Timestamp and other special tokens are left out:
    /// they sit at and above `specialTokenBegin`.
    static func segment(_ segment: TranscriptionSegment,
                        specialTokenBegin: Int?) -> TranscriptSanitizer.Segment {
        var sum = 0.0
        var count = 0
        for entry in segment.tokenLogProbs {
            for (token, logProb) in entry {
                if let specialTokenBegin, token >= specialTokenBegin { continue }
                sum += exp(Double(logProb))
                count += 1
            }
        }
        return TranscriptSanitizer.Segment(
            start: Double(segment.start), end: Double(segment.end), text: segment.text,
            probability: count > 0 ? sum / Double(count) : nil)
    }
}
