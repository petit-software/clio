import Testing
import Foundation
import WhisperKit
@testable import ClioCore

/// Whether letting a model go gives the memory back — the claim behind
/// Settings ▸ Model's "Keep model in memory", which read nothing for its
/// first eleven releases.
///
///     CLIO_INTEGRATION=1 swift test --filter ModelResidency
///
/// Runs on the models installed in the app's own folder and downloads
/// nothing: the speech model `CLIO_INTEGRATION_MODEL` names if it is
/// installed, else the first installed; the GGUF `CLIO_SUMMARY_MODEL` names,
/// else the first installed summary model. Either test is skipped when its
/// model is not there.
///
/// What is measured is this process's physical footprint. A CoreML model's
/// Neural Engine share is charged to the system's `aned`, so the speech
/// model's numbers are a floor, not the whole cost.
private let enabled = ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil

@Suite("ModelResidency", .enabled(if: enabled), .serialized)
struct ModelResidency {

    private func speak(_ text: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-residency-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-r", "175", "-o", file.path, text]
        try say.run()
        say.waitUntilExit()
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    private func footprint() throws -> Int { try #require(ProcessMemory.footprint) }

    private func report(_ what: String, before: Int, loaded: Int, after: Int) {
        print("[residency] \(what): idle \(ProcessMemory.describe(before))"
              + " → loaded \(ProcessMemory.describe(loaded))"
              + " (+\(ProcessMemory.describe(loaded - before)))"
              + " → freed \(ProcessMemory.describe(after))"
              + " (+\(ProcessMemory.describe(after - before)) over idle)")
    }

    /// Loaded, used, freed, and most of the growth given back; then loaded
    /// again, since a cold load after a free is the path the toggle adds.
    @Test("The speech model gives its memory back when unloaded, and loads again")
    func speechModel() async throws {
        let manager = await ModelManager()
        let wanted = ProcessInfo.processInfo.environment["CLIO_INTEGRATION_MODEL"]
        let installed = await manager.installed(.speech)
        guard let model = installed.first(where: { $0.id == wanted }) ?? installed.first else {
            print("[residency] no speech model installed; skipping")
            return
        }
        let samples = try speak("The quick brown fox jumps over the lazy dog.")
        let engine = WhisperKitEngine()

        let before = try footprint()
        try await engine.load(model: model)
        let first = try await engine.transcribe(samples: samples, options: TranscribeOptions())
        #expect(first.text.lowercased().contains("fox"))
        let loaded = try footprint()

        await engine.unload()
        try await Task.sleep(for: .seconds(1))
        let after = try footprint()
        report(model.id, before: before, loaded: loaded, after: after)

        let growth = loaded - before
        #expect(growth > 20 * 1_048_576, "the load was not visible in the footprint")
        #expect(after - before < growth / 2, "freeing the model gave back less than half of what loading took")

        let began = ContinuousClock.now
        try await engine.load(model: model)
        let second = try await engine.transcribe(samples: samples, options: TranscribeOptions())
        print("[residency] loaded again in \((ContinuousClock.now - began).formatted()) and transcribed")
        #expect(second.text.lowercased().contains("fox"))
        await engine.unload()
    }

    @Test("The summary model gives its memory back when unloaded")
    func summaryModel() async throws {
        let named = ProcessInfo.processInfo.environment["CLIO_SUMMARY_MODEL"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let manager = await ModelManager()
        let installed = await manager.installed(.language).first?.weightsFile
        guard let file = named ?? installed else {
            print("[residency] no summary model installed; skipping")
            return
        }
        let model = LocalSummaryModel(file: file, idleTime: .seconds(60))

        let before = try footprint()
        let answer = try await model.respond(instructions: "Answer in one word.",
                                             prompt: "What colour is grass? /no_think")
        #expect(!answer.isEmpty)
        let loaded = try footprint()

        await model.unload()
        try await Task.sleep(for: .seconds(1))
        let after = try footprint()
        report(file.lastPathComponent, before: before, loaded: loaded, after: after)

        let growth = loaded - before
        #expect(growth > 100 * 1_048_576, "the load was not visible in the footprint")
        #expect(after - before < growth / 2, "freeing the model gave back less than half of what loading took")
    }

    /// A shorter idle time set while the weights are waiting to be freed
    /// frees them at the new length, not the old.
    @Test("Shortening the idle time frees the weights sooner")
    func idleTimeFollowsTheSetting() async throws {
        let manager = await ModelManager()
        guard let file = (await manager.installed(.language)).first?.weightsFile else {
            print("[residency] no summary model installed; skipping")
            return
        }
        let model = LocalSummaryModel(file: file, idleTime: .seconds(600))
        _ = try await model.respond(instructions: "Answer in one word.",
                                    prompt: "What colour is grass? /no_think")
        #expect(await model.isLoaded)
        await model.setIdleTime(.seconds(1))
        try await Task.sleep(for: .seconds(3))
        #expect(await model.isLoaded == false)
    }
}
