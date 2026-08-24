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
