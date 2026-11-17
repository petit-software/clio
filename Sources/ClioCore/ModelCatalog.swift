import Foundation

public enum QualityTier: String, Codable, Sendable, CaseIterable {
    case fast
    case balanced
    case best

    public var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .best: return "Best quality"
        }
    }
}

/// What a model is for. Clio downloads three kinds into one folder: speech
/// models for WhisperKit; language models — GGUF files run by llama.cpp —
/// that write meeting summaries; and the speaker models SpeakerKit tells
/// the voices on a call apart with.
public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case speech
    case language
    case speaker
}

public enum ModelLanguages: String, Codable, Sendable {
    case english
    case multilingual

    public var label: String {
        switch self {
        case .english: return "English only"
        case .multilingual: return "Multilingual"
        }
    }
}

/// One downloadable model.
///
/// `id` is the folder name inside the Hugging Face repo, which is also the
/// folder name we install it under — one identifier, no mapping table.
public struct CatalogModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var repo: String
    /// The matching `openai/whisper-*` repo, whose tokenizer WhisperKit needs.
    /// The CoreML model folders do not carry one, so we install it alongside —
    /// otherwise the first transcription reaches for the network, which the
    /// whole point of this app is not to do.
    public var tokenizerRepo: String?
    public var approximateBytes: Int64
    public var tier: QualityTier
    public var languages: ModelLanguages
    public var note: String?
    /// No longer offered for download, but kept so a copy someone already
    /// has stays visible in Settings — usable, and deletable. Dropping the
    /// entry instead would leave a gigabyte on disk with no row to remove it
    /// from, still quietly in use if it was the active model.
    public var retired: Bool
    /// Speech, unless the catalog says otherwise: every entry written
    /// before language models existed is a Whisper model.
    public var kind: ModelKind
    /// One file to take from the repo's root, for a model that is a single
    /// file — a GGUF — rather than a folder named `id`. It is installed as
    /// `<models>/<id>/<fileName>`, so every model is still a folder.
    public var fileName: String?
    /// The folder of the repo to list, when it is not one named `id`: ""
    /// for the repo's root. The speaker models are several folders of one
    /// repo, taken from its root.
    public var repoFolder: String?
    /// The least memory, in gigabytes, a Mac needs to run it at all. Under
    /// it Settings does not offer the download. Nil: runs anywhere.
    public var minimumMemoryGB: Int?
    /// The memory from which it is the one to suggest. Of the models a Mac
    /// meets this for, the one asking most is recommended.
    public var recommendedMemoryGB: Int?

    public init(id: String, displayName: String, repo: String,
                tokenizerRepo: String? = nil,
                approximateBytes: Int64, tier: QualityTier,
                languages: ModelLanguages, note: String? = nil,
                retired: Bool = false,
                kind: ModelKind = .speech, fileName: String? = nil,
                repoFolder: String? = nil,
                minimumMemoryGB: Int? = nil, recommendedMemoryGB: Int? = nil) {
        self.repoFolder = repoFolder
        self.minimumMemoryGB = minimumMemoryGB
        self.recommendedMemoryGB = recommendedMemoryGB
        self.id = id
        self.displayName = displayName
        self.repo = repo
        self.tokenizerRepo = tokenizerRepo
        self.kind = kind
        self.fileName = fileName
        self.approximateBytes = approximateBytes
        self.tier = tier
        self.languages = languages
        self.note = note
        self.retired = retired
    }

    /// Written out so `retired` can be missing: an older `models.json` in
    /// Application Support has no such key, and the synthesized decoder would
    /// reject the whole file for it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        repo = try c.decode(String.self, forKey: .repo)
        tokenizerRepo = try c.decodeIfPresent(String.self, forKey: .tokenizerRepo)
        approximateBytes = try c.decode(Int64.self, forKey: .approximateBytes)
        tier = try c.decode(QualityTier.self, forKey: .tier)
        languages = try c.decode(ModelLanguages.self, forKey: .languages)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        retired = try c.decodeIfPresent(Bool.self, forKey: .retired) ?? false
        kind = try c.decodeIfPresent(ModelKind.self, forKey: .kind) ?? .speech
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        repoFolder = try c.decodeIfPresent(String.self, forKey: .repoFolder)
        minimumMemoryGB = try c.decodeIfPresent(Int.self, forKey: .minimumMemoryGB)
        recommendedMemoryGB = try c.decodeIfPresent(Int.self, forKey: .recommendedMemoryGB)
    }

    /// Whether a Mac with `memoryGB` of memory can run it.
    public func runs(onMemoryGB memoryGB: Int) -> Bool {
        memoryGB >= (minimumMemoryGB ?? 0)
    }

    /// The folder in the repo the model's files are listed from: the model's
    /// own for a WhisperKit folder, the root for a single file.
    var repoPath: String { repoFolder ?? (fileName == nil ? id : "") }
}

/// The list of models we offer.
///
/// Resolution order: a `models.json` the user (or a future CDN refresh) put in
/// Application Support, then the one in the app bundle, then the built-in
/// constant. The last one exists so a stripped or corrupt bundle degrades to a
/// working app rather than an empty Model tab.
///
/// Read through `Bundle.main`, deliberately not SwiftPM's `Bundle.module`. That
/// accessor looks for its bundle at the *root* of the .app (which codesign does
/// not want), falls back to a build path hardcoded to the machine that compiled
/// it, and calls `fatalError` when it finds neither — so a correct-looking
/// build would crash on any Mac but this one.
public enum ModelCatalog {

    public static func load(
        overrideURL: URL = AppPaths.supportDirectory
            .appendingPathComponent("models.json")
    ) -> [CatalogModel] {
        if let models = decode(contentsOf: overrideURL) { return models }
        if let url = Bundle.main.url(forResource: "models", withExtension: "json"),
           let models = decode(contentsOf: url) {
            return models
        }
        return builtIn
    }

    static func decode(contentsOf url: URL) -> [CatalogModel]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CatalogModel].self, from: data)
    }

    /// Sizes here are measured from the repo, not copied from the spec.
    ///
    /// Worth knowing: the spec's suggested sizes name the *quantized* variants.
    /// `distil-whisper_distil-large-v3` is 1.5 GB on disk; the ~600 MB model
    /// the spec means is `distil-whisper_distil-large-v3_594MB`. Same for the
    /// others, so the quantized ids are what ship.
    public static let builtIn: [CatalogModel] = [
        CatalogModel(
            id: "openai_whisper-tiny",
            displayName: "Whisper Tiny",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-tiny",
            approximateBytes: 77_000_000,
            tier: .fast,
            languages: .multilingual,
            note: "Smallest download. Good for checking everything works."),
        CatalogModel(
            id: "openai_whisper-small_216MB",
            displayName: "Whisper Small",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-small",
            approximateBytes: 217_000_000,
            tier: .fast,
            languages: .multilingual,
            note: "Low-RAM machines, multilingual."),
        CatalogModel(
            id: "distil-whisper_distil-large-v3_594MB",
            displayName: "Distil Large v3",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-large-v3",
            approximateBytes: 595_000_000,
            tier: .balanced,
            languages: .english,
            note: "Default. English, fast, accurate."),
        // OpenAI's large-v3-turbo, which Argmax names by its release date.
        // Argmax's own "_turbo" suffix is something else: a streaming build,
        // older than OpenAI's turbo, which Clio has no use for since it
        // transcribes a finished recording.
        CatalogModel(
            id: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "Whisper Large v3 Turbo",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-large-v3-turbo",
            approximateBytes: 627_000_000,
            tier: .best,
            languages: .multilingual,
            note: "Best quality, multilingual."),
        // What shipped as "Large v3 Turbo" until 0.12. It is full large-v3 —
        // 32 decoder layers to the real turbo's 4 — at 1 GB, and Argmax leaves
        // it off the list of models supported on M1 Macs.
        CatalogModel(
            id: "openai_whisper-large-v3_turbo_954MB",
            displayName: "Whisper Large v3",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-large-v3",
            approximateBytes: 1_053_000_000,
            tier: .best,
            languages: .multilingual,
            note: "No longer offered. Large v3 Turbo is close in accuracy, smaller and much faster.",
            retired: true),

        // Summary models: one GGUF each, 4-bit, from repos that track the
        // model's own release. Apple's on-device model holds about four
        // thousand tokens and writes a summary from pieces; these hold the
        // whole transcript of most meetings and write one from all of it.
        // Both are instruction-tuned without a "thinking" mode, so the
        // answer is the summary and nothing has to be cut out of it.
        CatalogModel(
            id: "qwen3-4b-instruct-2507-q4_k_m",
            displayName: "Qwen3 4B",
            repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
            approximateBytes: 2_497_000_000,
            tier: .balanced,
            languages: .multilingual,
            note: "Better summaries than Apple Intelligence; reads the whole transcript. Needs 8 GB of memory.",
            kind: .language,
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            minimumMemoryGB: 8, recommendedMemoryGB: 8),
        CatalogModel(
            id: "gemma-3-12b-it-q4_k_m",
            displayName: "Gemma 3 12B",
            repo: "ggml-org/gemma-3-12b-it-GGUF",
            approximateBytes: 7_300_000_000,
            tier: .best,
            languages: .multilingual,
            note: "Best summaries. Slower, and needs 16 GB of memory or more.",
            kind: .language,
            fileName: "gemma-3-12b-it-Q4_K_M.gguf",
            minimumMemoryGB: 16, recommendedMemoryGB: 24),
        CatalogModel(
            id: "speakerkit-pyannote",
            displayName: "Speaker Recognition",
            repo: "argmaxinc/speakerkit-coreml",
            approximateBytes: 17_000_000,
            tier: .balanced,
            languages: .multilingual,
            note: "Tells the voices on a call apart, so the transcript says who spoke instead of Others.",
            kind: .speaker,
            repoFolder: ""),
    ]

    /// This Mac's memory in whole gigabytes, as the catalog counts it.
    public static var memoryGB: Int {
        // For looking at Settings ▸ Model as a smaller Mac would show it:
        // CLIO_MEMORY_GB=8. Only what is offered and suggested follows it.
        if let pretend = ProcessInfo.processInfo.environment["CLIO_MEMORY_GB"].flatMap(Int.init) {
            return pretend
        }
        return Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    /// The model of `kind` to suggest on a Mac with `memoryGB`: of those it
    /// is recommended for, the one that asks for most. Nil when none is —
    /// a summary model on a Mac under 8 GB, where Apple's is the one to use.
    public static func recommended(_ kind: ModelKind, in catalog: [CatalogModel],
                                   memoryGB: Int = ModelCatalog.memoryGB) -> CatalogModel? {
        catalog
            .filter { $0.kind == kind && !$0.retired }
            .filter { ($0.recommendedMemoryGB).map { memoryGB >= $0 } ?? false }
            .max { ($0.recommendedMemoryGB ?? 0) < ($1.recommendedMemoryGB ?? 0) }
    }

    /// The models that tell voices apart. One entry: there is no choosing.
    public static let speakerModelID = "speakerkit-pyannote"

    public static let defaultModelID = "distil-whisper_distil-large-v3_594MB"
    /// The summary model Settings offers first, to anyone on Apple's.
    public static let defaultSummaryModelID = "qwen3-4b-instruct-2507-q4_k_m"
}
