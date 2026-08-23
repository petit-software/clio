import Testing
import Foundation
import WhisperKit
@testable import ScribeCore

/// End-to-end against the real Hugging Face repo and a real CoreML model.
///
/// Off by default: it downloads ~81 MB and takes a while. Run it deliberately:
///
///     SCRIBE_INTEGRATION=1 swift test --filter Integration
///
/// It is the only thing that actually proves the ASR path works, so it exists
/// rather than being replaced by a mock that always agrees with us.
private let integrationEnabled =
    ProcessInfo.processInfo.environment["SCRIBE_INTEGRATION"] != nil

@Suite("Integration", .enabled(if: integrationEnabled))
struct IntegrationTests {

    /// Speech to transcribe, produced by macOS's own synthesizer so the test
    /// carries no audio fixture.
    private func makeSpokenAudio(_ phrase: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("speech.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "170", "-o", file.path, phrase]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        return try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    @Test("A downloaded model transcribes real speech, entirely offline")
    func endToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = try #require(
            ModelCatalog.builtIn.first { $0.id == "openai_whisper-tiny" })

        // 1. Install it the way the app does.
        let manager = await ModelManager(
            transport: HuggingFaceTransport(),
            modelsDirectory: root,
            huggingFaceCache: URL(fileURLWithPath: "/nonexistent"))
        await manager.download(model)

        let deadline = ContinuousClock.now + .seconds(600)
        while await !manager.isInstalled(model.id) {
            if let failure = await manager.failures[model.id] {
                Issue.record("Download failed: \(failure)")
                return
            }
            guard ContinuousClock.now < deadline else {
                Issue.record("Download timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let installed = try #require(await manager.installed.first)

        // 2. The tokenizer must be installed alongside, or the first
        //    transcription silently reaches for the network.
        let tokenizer = ModelManager.tokenizerDirectory(for: installed)
            .appendingPathComponent("tokenizer.json")
        #expect(FileManager.default.fileExists(atPath: tokenizer.path))

        // 3. Load and transcribe.
        let engine = WhisperKitEngine()
        try await engine.load(model: installed)
        #expect(await engine.isLoaded)

        let samples = try makeSpokenAudio("The quick brown fox jumps over the lazy dog.")
        #expect(samples.count > 16_000)

        let transcript = try await engine.transcribe(
            samples: samples, options: TranscribeOptions(language: "en"))

        let text = transcript.text.lowercased()
        print("[integration] transcript: \(transcript.text)")
        #expect(text.contains("quick brown fox"))
        #expect(text.contains("lazy dog"))

        await engine.unload()
        #expect(await engine.isLoaded == false)
    }
}
