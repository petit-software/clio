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

@Test("A meeting's vocabulary is the user's words, the people invited, then the title's names")
func meetingVocabulary() {
    let attendees = [MeetingAttendee(name: "Ana Ruiz"),
                     MeetingAttendee(name: "lee@example.com"),
                     MeetingAttendee(markdown: "Tom Berg (declined)")]
    let terms = TranscriptFormatter.meetingVocabulary(
        user: ["Clio", " kiln "], title: "Weekly sync with Acme on Kiln Q3 OKRs",
        attendees: attendees)
    // "Kiln" is the user's "kiln" again; "Weekly" is only first; the
    // address and the one who declined are not names to listen for.
    #expect(terms == ["Clio", "kiln", "Ana Ruiz", "Acme", "Q3", "OKRs"])

    #expect(TranscriptFormatter.meetingVocabulary(user: ["Clio"], title: nil, attendees: [])
            == ["Clio"])
}

@Test("A long invitation is cut to what Whisper's prompt holds, the user's words kept")
func meetingVocabularyIsCapped() {
    let attendees = (0..<200).map { MeetingAttendee(name: "Person Number \($0)") }
    let terms = TranscriptFormatter.meetingVocabulary(user: ["Clio"], title: nil,
                                                      attendees: attendees)
    #expect(terms.first == "Clio")
    #expect(terms.count < 200)
    #expect((TranscriptFormatter.initialPrompt(from: terms) ?? "").count
            <= TranscriptFormatter.vocabularyLimit)
}

@Test("A segment after the end of the audio is dropped, one running past it is cut")
func sanitizerDropsWhatWasNotSaid() {
    typealias Segment = TranscriptSanitizer.Segment
    let segments = [Segment(start: 0, end: 4, text: "<|0.00|> Hello there.<|4.00|>", probability: 0.9),
                    Segment(start: 8, end: 12, text: " Still talking", probability: 0.8),
                    Segment(start: 10, end: 11, text: " Thanks for watching!", probability: 0.9)]
    let kept = TranscriptSanitizer.sanitize(segments, audioDuration: 10)
    #expect(kept.count == 2)
    #expect(kept[1].end == 10)
    #expect(TranscriptSanitizer.text(of: kept) == "Hello there. Still talking")
}

@Test("A sentence the model is sure of, over a stretch with no sound in it, was not said")
func sanitizerDropsWhatHadNoSound() {
    typealias Segment = TranscriptSanitizer.Segment
    // 3.4 s of voice, then 3 s of nothing: 50 frames a second.
    let sound = TranscriptSanitizer.Sound(frames: Array(repeating: true, count: 170)
                                          + Array(repeating: false, count: 150))
    let said = Segment(start: 0, end: 3.32, text: "We ship on Thursday.", probability: 0.93)
    // Starts in the last of the speech, runs to the end: a tenth of a second of sound in three.
    let invented = Segment(start: 3.32, end: 6.4, text: "Thank you.", probability: 0.8)
    #expect(TranscriptSanitizer.sanitize([said, invented], audioDuration: 6.4, sound: sound) == [said])
    // Without knowing where the sound was, it cannot be told.
    #expect(TranscriptSanitizer.sanitize([said, invented], audioDuration: 6.4).count == 2)
    // A short real word is all sound, however short; a long turn with pauses in it is mostly sound.
    let yes = Segment(start: 3.0, end: 3.3, text: "Yes.", probability: 0.9)
    #expect(TranscriptSanitizer.sanitize([yes], audioDuration: 6.4, sound: sound) == [yes])
    let paused = TranscriptSanitizer.Sound(frames: Array(repeating: true, count: 40)
                                           + Array(repeating: false, count: 200)
                                           + Array(repeating: true, count: 40))
    let turn = Segment(start: 0, end: 5.6, text: "Well… let me think.", probability: 0.7)
    #expect(TranscriptSanitizer.sanitize([turn], audioDuration: 5.6, sound: paused) == [turn])

    // From samples: a tone is sound, zeros are not, and a recording of
    // nothing but faint noise is not taken for silence throughout.
    let tone = (0..<16_000).map { Float(sin(Double($0) * 0.2)) * 0.3 }
    let heard = TranscriptSanitizer.Sound(samples: tone + [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    #expect(abs(heard.seconds(from: 0, to: 2) - 1) < 0.05)
    #expect(heard.seconds(from: 1.1, to: 2) == 0)
    let faint = TranscriptSanitizer.Sound(samples: (0..<16_000).map { _ in Float.random(in: -0.002...0.002) },
                                          sampleRate: 16_000)
    #expect(faint.seconds(from: 0, to: 1) > 0.9)
}

@Test("A last word the model was unsure of is dropped; a sure one, or a sentence, is kept")
func sanitizerDropsATrailingGuess() {
    typealias Segment = TranscriptSanitizer.Segment
    let hello = Segment(start: 0, end: 4, text: "Hello there.", probability: 0.9)
    func kept(_ last: Segment) -> Int {
        TranscriptSanitizer.sanitize([hello, last], audioDuration: 10).count
    }
    #expect(kept(Segment(start: 5, end: 6, text: " you", probability: 0.1)) == 1)
    #expect(kept(Segment(start: 5, end: 6, text: " Yes.", probability: 0.8)) == 2)
    #expect(kept(Segment(start: 5, end: 6, text: " not sure really", probability: 0.1)) == 2)
    #expect(kept(Segment(start: 5, end: 6, text: " you", probability: nil)) == 2)
    // Only the last one: an unsure word in the middle was followed by speech.
    let middle = TranscriptSanitizer.sanitize(
        [Segment(start: 0, end: 1, text: "um", probability: 0.1), hello], audioDuration: 10)
    #expect(middle.count == 2)
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
    #expect(settings.meetingsFolderPath == nil)
    #expect(settings.meetingSummaries == true)
    #expect(settings.summaryModelID == nil)
    #expect(settings.meetingDetection == true)
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

// MARK: - Pill style

@Test("A settings file from when the pill's look was a setting still loads")
func retiredPillKeysAreSkipped() throws {
    var expected = Settings()
    expected.pillSize = .large
    let json = """
    {"pillOpacity": 1, "pillClearGlass": true, "pillSize": "large",
     "pillStyle": {"adaptive": true, "glassTintDark": 0.5}}
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded == expected)
}
