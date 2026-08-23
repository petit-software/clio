import Foundation

/// One typed struct, one JSON file.
///
/// The spec (§6) is explicit about this: Handy lists "settings have become
/// bloated and messy" as tech debt, so there are no scattered UserDefaults
/// keys here. `schemaVersion` is what lets us migrate later without guessing.
public struct Settings: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1

    // General
    public var hotkey: Hotkey = .defaultHotkey
    public var hotkeyMode: HotkeyMode = .pushToTalk
    public var launchAtLogin: Bool = false
    public var showMenuBarIcon: Bool = true

    // Model
    public var activeModelID: String? = nil
    public var keepModelInMemory: Bool = true

    // Audio
    /// `nil` means "system default input".
    public var inputDeviceUID: String? = nil
    public var voiceActivityDetection: Bool = true
    public var vadSensitivity: Double = 0.5
    public var maxRecordingSeconds: Double = 120

    // Transcription
    /// `nil` means auto-detect.
    public var language: String? = nil
    public var translateToEnglish: Bool = false
    public var customVocabulary: [String] = []
    public var wordReplacements: [WordReplacement] = []

    // Output
    public var outputAction: OutputAction = .pasteAutomatically
    public var injectionMethod: InjectionMethod = .paste
    public var trimTrailingPunctuation: Bool = false
    public var capitalizeFirstLetter: Bool = true

    // Feedback
    public var overlayPosition: OverlayPosition = .bottomCenter
    public var playSoundOnStart: Bool = true
    public var playSoundOnStop: Bool = true
    public var playSoundOnCancel: Bool = true

    // History
    /// Off by default: dictated text is whatever the user happened to say, so
    /// keeping a log of it on disk is opt-in.
    public var keepHistoryOnDisk: Bool = false

    public init() {}
}

public struct WordReplacement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var find: String
    public var replace: String

    public init(id: UUID = UUID(), find: String = "", replace: String = "") {
        self.id = id
        self.find = find
        self.replace = replace
    }
}

public enum OutputAction: String, Codable, Sendable, CaseIterable {
    case pasteAutomatically
    case copyOnly

    public var label: String {
        switch self {
        case .pasteAutomatically: return "Paste automatically"
        case .copyOnly: return "Copy to clipboard only"
        }
    }
}

public enum InjectionMethod: String, Codable, Sendable, CaseIterable {
    case paste
    case typeCharacters

    public var label: String {
        switch self {
        case .paste: return "Paste (⌘V)"
        case .typeCharacters: return "Type characters"
        }
    }
}

public enum OverlayPosition: String, Codable, Sendable, CaseIterable {
    case none
    case topCenter
    case bottomCenter
    case nearCursor

    public var label: String {
        switch self {
        case .none: return "Hidden"
        case .topCenter: return "Top center"
        case .bottomCenter: return "Bottom center"
        case .nearCursor: return "Near cursor"
        }
    }
}
