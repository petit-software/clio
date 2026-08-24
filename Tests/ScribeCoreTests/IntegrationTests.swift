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

// Serialized: the tests share one installed model directory, and two of them
// installing it at once raced on the .partial files. Serial also keeps the
// timing test off a CPU busy transcribing for another test.
@Suite("Integration", .enabled(if: integrationEnabled), .serialized)
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

    /// Installed once and kept, so a second run of this suite does not
    /// re-download 81 MB. Cleared by a reboot like anything else in /tmp.
    private var sharedModelRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-integration-models", isDirectory: true)
    }

    private func installTinyModel() async throws -> InstalledModel {
        let root = sharedModelRoot
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)

        let model = try #require(
            ModelCatalog.builtIn.first { $0.id == "openai_whisper-tiny" })

        let manager = await ModelManager(
            transport: HuggingFaceTransport(),
            modelsDirectory: root,
            huggingFaceCache: URL(fileURLWithPath: "/nonexistent"))

        if await !manager.isInstalled(model.id) {
            await manager.download(model)
            let deadline = ContinuousClock.now + .seconds(600)
            while await !manager.isInstalled(model.id) {
                if let failure = await manager.failures[model.id] {
                    throw IntegrationError.downloadFailed(failure)
                }
                guard ContinuousClock.now < deadline else {
                    throw IntegrationError.downloadFailed("timed out")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }

        return try #require(await manager.installed.first { $0.id == model.id })
    }

    enum IntegrationError: Error { case downloadFailed(String) }

    @Test("A downloaded model transcribes real speech, entirely offline")
    func endToEnd() async throws {
        let installed = try await installTinyModel()

        // The tokenizer must be installed alongside, or the first
        // transcription silently reaches for the network.
        let tokenizer = ModelManager.tokenizerDirectory(for: installed)
            .appendingPathComponent("tokenizer.json")
        #expect(FileManager.default.fileExists(atPath: tokenizer.path))

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

    /// Measured, and it corrected the assumption behind this milestone.
    ///
    /// Whisper transcribes in 30-second windows and pads to fill one. Trimming
    /// 8s of silence off a 10s clip therefore buys nothing at all — both are a
    /// single window, and both measured ~47ms. The inference win only appears
    /// when trimming removes a whole window, which needs the padded clip to
    /// cross 30 seconds.
    ///
    /// For ordinary dictation, under 30 seconds, trimming is a *quality* fix
    /// (Whisper hallucinates text over silence), not a speed one.
    @Test("Trimming silence cuts a whole Whisper window off a long clip")
    func vadCutsLatency() async throws {
        let installed = try await installTinyModel()
        let engine = WhisperKitEngine()
        try await engine.load(model: installed)
        defer { Task { await engine.unload() } }

        let speech = try makeSpokenAudio("The quick brown fox jumps over the lazy dog.")
        // 16s either side, so the padded clip is ~35s: two windows to the
        // trimmed clip's one.
        let padding = [Float](repeating: 0,
                              count: Int(16 * AudioRecorder.sampleRate))
        let padded = padding + speech + padding
        #expect(Double(padded.count) / AudioRecorder.sampleRate > 30)

        let options = TranscribeOptions(language: "en")

        // Warm up: the first run pays for lazy CoreML setup and would make
        // whichever case ran first look slower.
        _ = try await engine.transcribe(samples: speech, options: options)

        let paddedStart = ContinuousClock.now
        let paddedResult = try await engine.transcribe(samples: padded, options: options)
        let paddedTime = ContinuousClock.now - paddedStart

        let trimmed = try #require(
            VoiceActivityTrimmer.trim(padded, sensitivity: 0.5))

        let trimmedStart = ContinuousClock.now
        let trimmedResult = try await engine.transcribe(samples: trimmed.samples,
                                                        options: options)
        let trimmedTime = ContinuousClock.now - trimmedStart

        print("[integration] padded  \(Double(padded.count) / AudioRecorder.sampleRate)s "
              + "in \(paddedTime)")
        print("[integration] trimmed \(Double(trimmed.samples.count) / AudioRecorder.sampleRate)s "
              + "in \(trimmedTime)")
        print("[integration] trimmed away \(trimmed.totalTrimmedSeconds)s")

        print("[integration] padded text:  \(paddedResult.text)")
        print("[integration] trimmed text: \(trimmedResult.text)")

        #expect(trimmed.samples.count < padded.count)
        #expect(trimmedTime < paddedTime)
        // The words still come back...
        #expect(trimmedResult.text.lowercased().contains("quick brown fox"))
        #expect(paddedResult.text.lowercased().contains("quick brown fox"))

        // ...and cleanly. This is the real reason to trim: Whisper invents
        // text over silence. The padded clip reliably comes back with a
        // trailing hallucination ("… lazy dog. you"); the trimmed one ends
        // where the speech does.
        #expect(trimmedResult.text.hasSuffix("dog."))
        #expect(trimmedResult.text.count <= paddedResult.text.count)
    }
}

/// Recording from a chosen microphone, for real.
///
/// Separate from the model tests because it needs the microphone permission,
/// which a test binary only has if the user granted it. Run with:
///
///     SCRIBE_INTEGRATION=1 swift test --filter MicrophoneIntegration
@Suite("MicrophoneIntegration", .enabled(if: integrationEnabled), .serialized)
struct MicrophoneIntegrationTests {

    @Test("Every listed microphone can actually be recorded from")
    func everyDeviceRecords() async throws {
        let devices = AudioDevices.availableInputs()
        try #require(!devices.isEmpty)

        for device in devices {
            let recorder = AudioRecorder()
            do {
                try recorder.start(maxSeconds: 5, deviceUID: device.id)
            } catch {
                Issue.record("\(device.name) failed to start: \(error)")
                continue
            }

            try await Task.sleep(for: .milliseconds(600))
            let samples = recorder.stop()

            // Samples arriving at all is the thing being checked. Whether they
            // are loud is a property of the room, not of the routing.
            let peak = samples.map(abs).max() ?? 0
            print("[mic] \(device.name): \(samples.count) samples, peak \(peak)")
            #expect(samples.count > Int(0.3 * AudioRecorder.sampleRate),
                    "\(device.name) produced almost no audio")
        }
    }

    @Test("An unplugged microphone falls back instead of failing")
    func missingDeviceFallsBack() async throws {
        let recorder = AudioRecorder()
        // Losing the words because a headset was unplugged is worse than
        // quietly recording from the default.
        try recorder.start(maxSeconds: 5, deviceUID: "a-device-that-is-not-here")
        try await Task.sleep(for: .milliseconds(400))
        let samples = recorder.stop()
        #expect(samples.count > Int(0.2 * AudioRecorder.sampleRate))
    }
}
