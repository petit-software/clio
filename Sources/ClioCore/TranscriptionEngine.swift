import Foundation

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var language: String?
    public var duration: TimeInterval

    public init(text: String, language: String? = nil, duration: TimeInterval = 0) {
        self.text = text
        self.language = language
        self.duration = duration
    }
}

public struct TranscribeOptions: Sendable {
    public var language: String?      // nil = auto-detect
    public var translateToEnglish: Bool
    public var initialPrompt: String? // seed with custom vocabulary

    public init(language: String? = nil,
                translateToEnglish: Bool = false,
                initialPrompt: String? = nil) {
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.initialPrompt = initialPrompt
    }
}

public struct InstalledModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var sizeBytes: Int64
    public var url: URL
    /// Told apart on disk: a folder of compiled Core ML models is speech, a
    /// folder holding a GGUF is language. The two must never be confused —
    /// a GGUF handed to WhisperKit as the fallback model is a dictation that
    /// fails.
    public var kind: ModelKind
    /// A model somewhere else on disk that the user pointed Clio at: a
    /// symbolic link in the models folder, to a folder or to a GGUF.
    /// Deleting one removes the link and leaves the model where it was.
    public var isLinked: Bool

    public init(id: String, displayName: String, sizeBytes: Int64, url: URL,
                kind: ModelKind = .speech, isLinked: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.url = url
        self.kind = kind
        self.isLinked = isLinked
    }

    /// Where the model's files really are — through the link, for a
    /// linked one.
    public var resolvedURL: URL {
        (weightsFile ?? url).resolvingSymlinksInPath()
    }

    /// The GGUF inside a language model's folder; nil for a speech model.
    public var weightsFile: URL? {
        guard kind == .language else { return nil }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.first { $0.lowercased().hasSuffix(".gguf") }
            .map { url.appendingPathComponent($0) }
    }
}

/// The seam WhisperKit goes behind (§5.4).
///
/// Milestone 2 adds `WhisperKitEngine`; nothing above this protocol changes
/// when it does, which is the point of introducing it now.
public protocol TranscriptionEngine: AnyObject, Sendable {
    var isLoaded: Bool { get async }
    func load(model: InstalledModel) async throws
    func unload() async
    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript
}

/// Stands in for WhisperKit until Milestone 2.
///
/// It returns an obviously-fake transcript on purpose — placeholder text that
/// reads like real speech would make a broken ASR path look like a working
/// one. The rest of the loop (record → overlay → clipboard → paste) is real
/// and can be exercised end to end against this.
public actor StubTranscriptionEngine: TranscriptionEngine {
    private var loaded = false
    private let latency: Duration

    public init(latency: Duration = .milliseconds(600)) {
        self.latency = latency
    }

    public var isLoaded: Bool { loaded }

    public func load(model: InstalledModel) async throws {
        guard !loaded else { return }
        try? await Task.sleep(for: .milliseconds(200))
        loaded = true
    }

    public func unload() async {
        loaded = false
    }

    public func transcribe(samples: [Float],
                           options: TranscribeOptions) async throws -> Transcript {
        try await Task.sleep(for: latency)
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let text = String(
            format: "[Clio stub] captured %.1fs of audio (%d samples). "
                  + "Real transcription arrives in Milestone 2.",
            seconds, samples.count)
        return Transcript(text: text, language: options.language, duration: seconds)
    }
}
