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
    /// Ten minutes, matching the maximum the Settings stepper offers.
    ///
    /// The recorder preallocates a buffer for this whole duration, so it is
    /// also 36 MB held while recording and a 3.3 ms allocation at hotkey-down
    /// — measured, and invisible beside the 180 ms push-to-talk hold. Being
    /// cut off mid-thought costs more than the memory does.
    public var maxRecordingSeconds: Double = 600

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
    /// Leave the transcript on the clipboard after pasting it.
    ///
    /// Off by default because pasting borrows the clipboard and puts back what
    /// was there — silently replacing whatever the user had copied is not a
    /// side effect a dictation app should have without being asked.
    public var keepTranscriptOnClipboard: Bool = false

    // Feedback
    public var overlayPosition: OverlayPosition = .bottomCenter
    /// How solid the pill's surface is, 0…1.
    ///
    /// 0 is bare glass, taking all of its colour from whatever is behind it;
    /// 1 is the flat surface the design was drawn as. The default keeps enough
    /// tint that the label stays legible over any backdrop, which is the thing
    /// that breaks first as this comes down.
    public var pillOpacity: Double = 0.30
    /// Swap the frosted glass for the far more transparent clear variant.
    /// A different effect, not merely less of the same one.
    public var pillClearGlass: Bool = false
    public var playSoundOnStart: Bool = true
    public var playSoundOnStop: Bool = true
    public var playSoundOnCancel: Bool = true

    // History
    /// Off by default: dictated text is whatever the user happened to say, so
    /// keeping a log of it on disk is opt-in.
    public var keepHistoryOnDisk: Bool = false

    public init() {}

    /// Decoded field by field, falling back to the default for anything absent
    /// or unreadable.
    ///
    /// Swift's synthesized decoder throws `keyNotFound` for a missing key even
    /// when the property has a default value — the defaults above are used by
    /// `init()` and ignored by decoding. So every field added to this struct
    /// made every existing settings file undecodable, and `SettingsStore` did
    /// the sane thing with a file it could not read: set it aside and start
    /// from defaults. The user lost their shortcut, their model and their
    /// microphone, and the only trace was a `settings.json.corrupt` nobody
    /// looks at. This is not hypothetical; it happened twice during
    /// development, and `schemaVersion` exists precisely so it should not have.
    ///
    /// `try?` rather than `decodeIfPresent` alone, so a value of the wrong
    /// shape — an enum case written by a newer version, say — costs that one
    /// setting rather than all of them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func readOptional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        schemaVersion = read(.schemaVersion, defaults.schemaVersion)

        hotkey = read(.hotkey, defaults.hotkey)
        hotkeyMode = read(.hotkeyMode, defaults.hotkeyMode)
        launchAtLogin = read(.launchAtLogin, defaults.launchAtLogin)
        showMenuBarIcon = read(.showMenuBarIcon, defaults.showMenuBarIcon)

        activeModelID = readOptional(.activeModelID, String.self)
        keepModelInMemory = read(.keepModelInMemory, defaults.keepModelInMemory)

        inputDeviceUID = readOptional(.inputDeviceUID, String.self)
        voiceActivityDetection = read(.voiceActivityDetection,
                                      defaults.voiceActivityDetection)
        vadSensitivity = read(.vadSensitivity, defaults.vadSensitivity)
        maxRecordingSeconds = read(.maxRecordingSeconds, defaults.maxRecordingSeconds)

        language = readOptional(.language, String.self)
        translateToEnglish = read(.translateToEnglish, defaults.translateToEnglish)
        customVocabulary = read(.customVocabulary, defaults.customVocabulary)
        wordReplacements = read(.wordReplacements, defaults.wordReplacements)

        outputAction = read(.outputAction, defaults.outputAction)
        injectionMethod = read(.injectionMethod, defaults.injectionMethod)
        trimTrailingPunctuation = read(.trimTrailingPunctuation,
                                       defaults.trimTrailingPunctuation)
        capitalizeFirstLetter = read(.capitalizeFirstLetter,
                                     defaults.capitalizeFirstLetter)

        overlayPosition = read(.overlayPosition, defaults.overlayPosition)
        // Clamped on the way in: a value outside 0…1 from a hand-edited file
        // would render an invisible or fully opaque pill with no way back.
        pillOpacity = min(1, max(0, read(.pillOpacity, defaults.pillOpacity)))
        pillClearGlass = read(.pillClearGlass, defaults.pillClearGlass)
        playSoundOnStart = read(.playSoundOnStart, defaults.playSoundOnStart)
        playSoundOnStop = read(.playSoundOnStop, defaults.playSoundOnStop)
        playSoundOnCancel = read(.playSoundOnCancel, defaults.playSoundOnCancel)

        keepTranscriptOnClipboard = read(.keepTranscriptOnClipboard,
                                         defaults.keepTranscriptOnClipboard)
        keepHistoryOnDisk = read(.keepHistoryOnDisk, defaults.keepHistoryOnDisk)
    }
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
    // Declaration order is what the Settings picker shows, so it reads across
    // the screen rather than in the order the cases happened to be added.
    case none
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight
    case nearCursor

    public var label: String {
        switch self {
        case .none: return "Hidden"
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        case .nearCursor: return "Near cursor"
        }
    }
}
