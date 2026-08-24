import Testing
import Foundation
@testable import ClioCore

// MARK: - Settings persistence

@MainActor
@Test("Settings round-trip through disk")
func settingsRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SettingsStore(fileURL: url)
    store.settings.capitalizeFirstLetter = false
    store.settings.maxRecordingSeconds = 45
    store.settings.customVocabulary = ["Clio", "WhisperKit"]
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.capitalizeFirstLetter == false)
    #expect(reloaded.settings.maxRecordingSeconds == 45)
    #expect(reloaded.settings.customVocabulary == ["Clio", "WhisperKit"])
}

@MainActor
@Test("A corrupt settings file falls back to defaults and is kept")
func corruptSettingsFallsBack() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-test-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
    }

    try Data("{ not json".utf8).write(to: url)
    let store = SettingsStore(fileURL: url)

    #expect(store.settings == Settings())
    #expect(FileManager.default.fileExists(
        atPath: url.appendingPathExtension("corrupt").path))
}

// MARK: - Formatting

@Test("Capitalization and punctuation trimming follow the settings")
func formatterAppliesSettings() {
    var settings = Settings()
    settings.capitalizeFirstLetter = true
    settings.trimTrailingPunctuation = true

    #expect(TranscriptFormatter.format("hello there.", settings: settings)
            == "Hello there")

    settings.capitalizeFirstLetter = false
    settings.trimTrailingPunctuation = false
    #expect(TranscriptFormatter.format("  hello there.  ", settings: settings)
            == "hello there.")
}

@Test("Replacements match whole words, not substrings")
func replacementsAreWholeWord() {
    var settings = Settings()
    settings.capitalizeFirstLetter = false
    settings.wordReplacements = [WordReplacement(find: "it", replace: "IT")]

    // "with" must survive a rule for "it".
    #expect(TranscriptFormatter.format("it works with it", settings: settings)
            == "IT works with IT")
}

@Test("Replacements are case-insensitive and skip empty rules")
func replacementsIgnoreCaseAndBlanks() {
    var settings = Settings()
    settings.capitalizeFirstLetter = false
    settings.wordReplacements = [
        WordReplacement(find: "whisperkit", replace: "WhisperKit"),
        WordReplacement(find: "   ", replace: "nope"),
    ]
    #expect(TranscriptFormatter.format("WhisperKit and whisperkit",
                                       settings: settings)
            == "WhisperKit and WhisperKit")
}

@Test("Custom vocabulary becomes an initial prompt")
func vocabularyBecomesPrompt() {
    #expect(TranscriptFormatter.initialPrompt(from: []) == nil)
    #expect(TranscriptFormatter.initialPrompt(from: ["  ", ""]) == nil)
    #expect(TranscriptFormatter.initialPrompt(from: ["Bart", " Clio "])
            == "Bart, Clio")
}

// MARK: - Hotkey

@Test("Default hotkey renders as ⌃;")
func defaultHotkeyDisplay() {
    #expect(Hotkey.defaultHotkey.displayString == "⌃;")
    #expect(Hotkey.defaultHotkey.isModifierOnly == false)
    #expect(Hotkey.defaultHotkey.requiresAppleKeyboard == false)
}

@Test("A modifier-only chord is recognised as such")
func modifierOnlyChord() {
    let chord = Hotkey(keyCode: nil, modifierFlags: 0x80000 /* option */)
    #expect(chord.isModifierOnly)
    #expect(chord.displayString == "⌥")
}

// MARK: - State machine

@Test("Only the in-flight states are busy and cancellable")
func stateFlags() {
    #expect(DictationState.idle.isBusy == false)
    #expect(DictationState.recording.isBusy)
    #expect(DictationState.transcribing.isBusy)
    #expect(DictationState.injecting.isBusy)
    #expect(DictationState.finished("x").isBusy == false)
    #expect(DictationState.failed("x").isCancellable == false)
}

// MARK: - Engine

@Test("The stub engine loads and returns a transcript")
func stubEngineTranscribes() async throws {
    let engine = StubTranscriptionEngine(latency: .milliseconds(1))
    let model = InstalledModel(id: "stub", displayName: "Stub",
                               sizeBytes: 0, url: URL(fileURLWithPath: "/tmp"))
    try await engine.load(model: model)
    #expect(await engine.isLoaded)

    let samples = [Float](repeating: 0, count: 16_000)
    let transcript = try await engine.transcribe(samples: samples,
                                                 options: TranscribeOptions())
    #expect(transcript.duration == 1.0)
    #expect(transcript.text.isEmpty == false)
}

// MARK: - Settings forward/backward compatibility

/// The regression that cost a user their settings twice.
///
/// Swift's synthesized decoder throws on a missing key even when the property
/// has a default, so before this was fixed, adding any field to `Settings`
/// made every existing settings.json undecodable — and the store's sensible
/// "set the unreadable file aside" behaviour then silently reset the shortcut,
/// the model and the microphone.
@Test("A settings file written before a field existed still loads")
func settingsSurviveAddedFields() throws {
    // Exactly the shape of the real file that broke: no activeModelID, no
    // inputDeviceUID, no keepHistoryOnDisk.
    let old = """
    {
      "schemaVersion": 1,
      "hotkey": { "modifierFlags": 262144 },
      "hotkeyMode": "pushToTalk",
      "launchAtLogin": false,
      "showMenuBarIcon": true,
      "keepModelInMemory": true,
      "voiceActivityDetection": true,
      "vadSensitivity": 0.5,
      "maxRecordingSeconds": 90,
      "translateToEnglish": false,
      "customVocabulary": ["Clio"],
      "wordReplacements": [],
      "outputAction": "pasteAutomatically",
      "injectionMethod": "paste",
      "trimTrailingPunctuation": false,
      "capitalizeFirstLetter": true,
      "overlayPosition": "bottomCenter",
      "playSoundOnStart": true,
      "playSoundOnStop": true,
      "playSoundOnCancel": true
    }
    """
    let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))

    // What the user had is kept...
    #expect(settings.maxRecordingSeconds == 90)
    #expect(settings.customVocabulary == ["Clio"])
    #expect(settings.hotkey.modifierFlags == 262144)
    // ...and fields that did not exist yet take their defaults.
    #expect(settings.keepHistoryOnDisk == false)
    #expect(settings.activeModelID == nil)
    #expect(settings.inputDeviceUID == nil)
}

@Test("An empty object decodes to defaults rather than throwing")
func settingsSurviveAnEmptyObject() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(settings == Settings())
}

@Test("One unreadable value costs that setting, not the whole file")
func settingsSurviveAnUnknownValue() throws {
    // A value a newer version wrote and this one does not understand. Losing
    // the overlay position is survivable; losing everything is not.
    let json = """
    { "maxRecordingSeconds": 42, "overlayPosition": "someFuturePosition",
      "hotkeyMode": "notAMode" }
    """
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

    #expect(settings.maxRecordingSeconds == 42)
    #expect(settings.overlayPosition == Settings().overlayPosition)
    #expect(settings.hotkeyMode == Settings().hotkeyMode)
}

@MainActor
@Test("Adding a field does not set the real file aside any more")
func storeDoesNotCorruptOnUpgrade() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-upgrade-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
    }

    // A file from an older version: valid, just missing newer keys.
    try Data(#"{"schemaVersion":1,"maxRecordingSeconds":77}"#.utf8).write(to: url)

    let store = SettingsStore(fileURL: url)
    #expect(store.settings.maxRecordingSeconds == 77)
    // The old behaviour renamed it to .corrupt and reset to defaults.
    #expect(FileManager.default.fileExists(
        atPath: url.appendingPathExtension("corrupt").path) == false)
}

@MainActor
@Test("A genuinely unreadable file is still set aside")
func storeStillQuarantinesGarbage() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-garbage-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
    }

    try Data("this is not json at all".utf8).write(to: url)
    let store = SettingsStore(fileURL: url)

    #expect(store.settings == Settings())
    #expect(FileManager.default.fileExists(
        atPath: url.appendingPathExtension("corrupt").path))
}
