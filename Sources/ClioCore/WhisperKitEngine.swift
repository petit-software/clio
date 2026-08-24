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
        guard let pipe else { throw EngineError.notLoaded }

        var decoding = DecodingOptions()
        decoding.task = options.translateToEnglish ? .translate : .transcribe
        decoding.language = options.language
        decoding.detectLanguage = options.language == nil
        // Dictation goes straight into a text field, so the special tokens and
        // timestamps Whisper emits are noise.
        decoding.skipSpecialTokens = true
        decoding.withoutTimestamps = true

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

        // Silence is a legitimate outcome, not an error — the coordinator turns
        // an empty transcript into "nothing was transcribed".
        return Transcript(
            text: text,
            language: results.first?.language ?? options.language,
            duration: Double(samples.count) / AudioRecorder.sampleRate)
    }
}
