import Testing
import Foundation
import WhisperKit
@testable import ClioCore

/// Why a long dictation comes back truncated.
///
/// Whisper transcribes in 30-second windows and uses the timestamp tokens it
/// emits to work out where the next window starts. This measures whether
/// suppressing those tokens costs everything after the first window.
private let enabled = ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil

@Suite("LongAudio", .enabled(if: enabled), .serialized)
struct LongAudioDiagnostic {

    private func speak(_ phrase: String) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-r", "175", "-o", file.path, phrase]
        try p.run(); p.waitUntilExit()
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    /// Long enough to need three windows, with a distinct marker at each end.
    private var longPhrase: String {
        let body = (1...14).map { "This is sentence number \($0), spoken to make the recording longer." }
        return (["The opening marker is aardvark."] + body + ["The closing marker is zeppelin."])
            .joined(separator: " ")
    }

    /// A recording longer than one Whisper window must come back whole.
    ///
    /// This goes through WhisperKitEngine rather than WhisperKit directly, so
    /// it covers the decoding options the app actually sends.
    @Test("A recording past 30 seconds is transcribed to the end")
    func longRecordingIsNotTruncated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-integration-models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let catalog = try #require(ModelCatalog.builtIn.first { $0.id == "openai_whisper-tiny" })
        let manager = await ModelManager(transport: HuggingFaceTransport(),
                                         modelsDirectory: root,
                                         huggingFaceCache: URL(fileURLWithPath: "/nonexistent"))
        if await !manager.isInstalled(catalog.id) {
            await manager.download(catalog)
            while await !manager.isInstalled(catalog.id) {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let installed = try #require(await manager.installed.first { $0.id == catalog.id })

        let samples = try speak(longPhrase)
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        print("[long] audio is \(String(format: "%.1f", seconds))s — \(Int(seconds / 30) + 1) windows")
        #expect(seconds > 60)

        let engine = WhisperKitEngine()
        try await engine.load(model: installed)
        let transcript = try await engine.transcribe(
            samples: samples, options: TranscribeOptions(language: "en"))
        await engine.unload()

        let text = transcript.text.lowercased()
        print("[long] \(transcript.text.count) chars")
        print("[long] tail: …\(String(transcript.text.suffix(70)))")

        // The marker only reachable from the third window. This failed with
        // withoutTimestamps = true, which is what made long dictations come
        // back as their first few seconds.
        #expect(text.contains("zeppelin"),
                "the recording was truncated before its end")

        // Roughly proportional to the audio. The truncated version was 154
        // characters for the same 60 seconds.
        #expect(transcript.text.count > 600,
                "only \(transcript.text.count) characters for \(Int(seconds))s of speech")

        // Timestamps are used for seeking but must not reach the text field.
        #expect(!transcript.text.contains("<|"))
    }
}
