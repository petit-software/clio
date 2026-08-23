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

    public init(id: String, displayName: String, repo: String,
                tokenizerRepo: String? = nil,
                approximateBytes: Int64, tier: QualityTier,
                languages: ModelLanguages, note: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.repo = repo
        self.tokenizerRepo = tokenizerRepo
        self.approximateBytes = approximateBytes
        self.tier = tier
        self.languages = languages
        self.note = note
    }
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
        CatalogModel(
            id: "openai_whisper-large-v3_turbo_954MB",
            displayName: "Whisper Large v3 Turbo",
            repo: "argmaxinc/whisperkit-coreml",
            tokenizerRepo: "openai/whisper-large-v3",
            approximateBytes: 1_053_000_000,
            tier: .best,
            languages: .multilingual,
            note: "Best quality, multilingual."),
    ]

    public static let defaultModelID = "distil-whisper_distil-large-v3_594MB"
}
