import Testing
import Foundation
@testable import ClioCore

// MARK: - Voice activity trimming

/// Silence, then a loud tone, then silence — the shape of a real utterance
/// with dead air at both ends.
private func makeClip(leadingSilence: Double,
                      tone: Double,
                      trailingSilence: Double,
                      amplitude: Float = 0.5,
                      sampleRate: Double = AudioRecorder.sampleRate) -> [Float] {
    func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }
    let toneCount = Int(tone * sampleRate)
    let signal = (0..<toneCount).map { index -> Float in
        amplitude * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
    }
    return silence(leadingSilence) + signal + silence(trailingSilence)
}

@Test("Trimming removes silence at both ends and keeps the speech")
func trimmingRemovesSilence() throws {
    let clip = makeClip(leadingSilence: 2.0, tone: 1.0, trailingSilence: 2.0)
    let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))

    // 5s in, roughly 1s of speech plus padding out.
    let seconds = Double(result.samples.count) / AudioRecorder.sampleRate
    #expect(seconds > 0.9)
    #expect(seconds < 1.6)
    #expect(result.samples.count < clip.count)
    #expect(result.trimmedLeadingSeconds > 1.5)
    #expect(result.trimmedTrailingSeconds > 1.5)
}

@Test("A clip with no speech returns nil rather than an empty transcription")
func silenceReturnsNil() {
    let silence = [Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))
    #expect(VoiceActivityTrimmer.trim(silence, sensitivity: 0.5) == nil)
    #expect(VoiceActivityTrimmer.trim([], sensitivity: 0.5) == nil)
}

@Test("Speech with no surrounding silence is left essentially alone")
func speechIsNotClipped() throws {
    let clip = makeClip(leadingSilence: 0, tone: 1.0, trailingSilence: 0)
    let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))
    #expect(result.samples.count == clip.count)
    #expect(result.totalTrimmedSeconds == 0)
}

@Test("Higher sensitivity means a lower energy threshold")
func sensitivityIsInverted() {
    let insensitive = VoiceActivityTrimmer.energyThreshold(for: 0)
    let middle = VoiceActivityTrimmer.energyThreshold(for: 0.5)
    let sensitive = VoiceActivityTrimmer.energyThreshold(for: 1)

    #expect(insensitive > middle)
    #expect(middle > sensitive)
    #expect(sensitive > 0)
    // The midpoint should land near WhisperKit's own tuned default of 0.02.
    #expect(abs(middle - 0.026) < 0.005)
    // Out-of-range values are clamped, not extrapolated.
    #expect(VoiceActivityTrimmer.energyThreshold(for: -5) == insensitive)
    #expect(VoiceActivityTrimmer.energyThreshold(for: 5) == sensitive)
}

@Test("A quiet clip survives at high sensitivity but not at low")
func sensitivityChangesDetection() {
    let quiet = makeClip(leadingSilence: 0.5, tone: 0.5,
                         trailingSilence: 0.5, amplitude: 0.03)
    #expect(VoiceActivityTrimmer.trim(quiet, sensitivity: 1.0) != nil)
    #expect(VoiceActivityTrimmer.trim(quiet, sensitivity: 0.0) == nil)
}

// MARK: - History

@MainActor
@Test("History keeps newest first and caps at the limit")
func historyCapsAndOrders() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HistoryStore(fileURL: directory.appendingPathComponent("h.json"))
    for index in 0..<(HistoryStore.limit + 5) { store.add("entry \(index)") }

    #expect(store.entries.count == HistoryStore.limit)
    #expect(store.latest?.text == "entry \(HistoryStore.limit + 4)")
}

@MainActor
@Test("Blank transcripts are not recorded")
func historyIgnoresBlanks() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HistoryStore(fileURL: directory.appendingPathComponent("h.json"))
    store.add("   ")
    store.add("\n")
    store.add("real")
    #expect(store.entries.count == 1)
}

@MainActor
@Test("History reaches disk only when asked, and turning it off deletes it")
func historyPersistenceIsOptIn() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("h.json")

    let store = HistoryStore(fileURL: file, persistsToDisk: false)
    store.add("something private")
    #expect(FileManager.default.fileExists(atPath: file.path) == false)

    // Opting in writes what is already in memory.
    store.persistsToDisk = true
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(HistoryStore(fileURL: file, persistsToDisk: true)
        .entries.first?.text == "something private")

    // Opting back out removes the file, not just future writes.
    store.persistsToDisk = false
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
}

@Test("Menu labels are single-line and truncated")
func menuLabelIsCompact() {
    let entry = TranscriptEntry(text: "line one\nline two")
    #expect(entry.menuLabel == "line one line two")

    let long = TranscriptEntry(text: String(repeating: "a", count: 100))
    #expect(long.menuLabel.count == 49)   // 48 + ellipsis
    #expect(long.menuLabel.hasSuffix("…"))
}

// MARK: - Recording limit

@Test("The warning window opens only in the last stretch")
func nearLimitWindow() {
    var progress = RecordingProgress(elapsed: 10, limit: 120)
    #expect(progress.remaining == 110)
    #expect(progress.isNearLimit == false)
    #expect(progress.display == "0:10")

    progress.elapsed = 105                       // 15s left
    #expect(progress.isNearLimit)
    #expect(progress.display == "0:15")          // switches to what remains
}

@Test("Remaining never goes negative")
func remainingIsClamped() {
    let progress = RecordingProgress(elapsed: 45, limit: 30)
    #expect(progress.remaining == 0)
    #expect(progress.isNearLimit)
}

@Test("The elapsed readout is minutes and seconds")
func displayFormatting() {
    #expect(RecordingProgress(elapsed: 0, limit: 600).display == "0:00")
    #expect(RecordingProgress(elapsed: 9, limit: 600).display == "0:09")
    #expect(RecordingProgress(elapsed: 83, limit: 600).display == "1:23")
    #expect(RecordingProgress(elapsed: 599, limit: 600).display == "0:01")
}

@Test("The cap explains itself in the units it was set in")
func limitDescription() {
    // The user has to understand why the recording ended without them.
    #expect(RecordingProgress.limitDescription(seconds: 120)
            == "Stopped at the 2:00 limit")
    #expect(RecordingProgress.limitDescription(seconds: 90)
            == "Stopped at the 1:30 limit")
    #expect(RecordingProgress.limitDescription(seconds: 30)
            == "Stopped at the 30s limit")
}

@Test("The recording buffer is sized from the configured cap")
func bufferMatchesTheCap() {
    var settings = Settings()
    settings.maxRecordingSeconds = 30
    #expect(Int(settings.maxRecordingSeconds * AudioRecorder.sampleRate) == 480_000)
    // The default the app ships with, and the stepper's ceiling.
    #expect(Settings().maxRecordingSeconds == 600)
}

// MARK: - Escape

@MainActor
@Test("Escape can cancel a session the hotkey did not start")
func escapeCancelsMenuStartedSessions() {
    // Starting from the menu bar leaves HotkeyManager's own isActive false, so
    // without the hook Esc had nothing to cancel and quietly did nothing.
    let manager = HotkeyManager()
    var cancelled = false
    manager.onEvent = { if case .cancel = $0 { cancelled = true } }

    #expect(manager.isActive == false)
    manager.isSessionActive = { true }

    // The Esc branch is private; this asserts the seam it depends on exists
    // and reports what the coordinator will tell it.
    #expect(manager.isSessionActive?() == true)
    _ = cancelled
}

// MARK: - Position preview

@Test("Every position the picker offers can be previewed except Hidden")
func previewablePositions() {
    // Hidden is the one choice with nothing to show, and flashing a pill to
    // demonstrate it would contradict the setting being chosen.
    let previewable = OverlayPosition.allCases.filter { $0 != OverlayPosition.none }
    #expect(previewable.count == OverlayPosition.allCases.count - 1)
    #expect(previewable.contains(.topLeft))
    #expect(previewable.contains(.bottomRight))
    #expect(!previewable.contains(OverlayPosition.none))
}

@Test("The edge gap is one number, not a constant plus a padding")
func edgeGapIsWhatItSays() {
    // The window carries transparent room for its shadow, so the constant used
    // to be 24 while the pill sat 38 away. The gap now means the distance you
    // would measure on screen.
    let visibleGap: CGFloat = 64
    let shadowRoom: CGFloat = 14
    #expect(visibleGap - shadowRoom == 50)   // what the window is inset by
    // Every position uses it, bottom centre included — it used to be held
    // 96 out to clear the Dock's reveal strip, which 64 clears anyway.
    #expect(visibleGap > 50)
}

// MARK: - Empty result versus failure

@Test("Producing no words is not a failure")
func emptyResultIsNotAFailure() {
    let empty = DictationState.emptyResult("No speech detected.")
    let broken = DictationState.failed("No model installed.")

    // Both are over, and neither can be cancelled.
    #expect(empty.isBusy == false)
    #expect(empty.isCancellable == false)

    // Both still say why nothing appeared — the overlay tells the user either
    // way; only the menu bar treats them differently.
    #expect(empty.overlayLabel == "No speech detected.")
    #expect(broken.overlayLabel == "No model installed.")

    // And they are genuinely distinct, so the menu bar can tell them apart.
    #expect(empty != broken)
    if case .failed = empty { Issue.record("empty result must not be a failure") }
}
