import Testing
import Foundation
@testable import ScribeCore

// MARK: - Settings persistence

@MainActor
@Test("Settings round-trip through disk")
func settingsRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SettingsStore(fileURL: url)
    store.settings.capitalizeFirstLetter = false
    store.settings.maxRecordingSeconds = 45
    store.settings.customVocabulary = ["Scribe", "WhisperKit"]
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.capitalizeFirstLetter == false)
    #expect(reloaded.settings.maxRecordingSeconds == 45)
    #expect(reloaded.settings.customVocabulary == ["Scribe", "WhisperKit"])
}

@MainActor
@Test("A corrupt settings file falls back to defaults and is kept")
func corruptSettingsFallsBack() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-test-\(UUID().uuidString).json")
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
    #expect(TranscriptFormatter.initialPrompt(from: ["Bart", " Scribe "])
            == "Bart, Scribe")
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
