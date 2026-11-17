import Testing
import Foundation
import WhisperKit
@testable import ClioCore

/// The real speaker models on real voices. Off by default — the first run
/// downloads the models (17 MB) into the integration cache in /tmp, through
/// Clio's own ModelManager, which is the download a user's Mac will make:
///
///     CLIO_INTEGRATION=1 swift test --filter SpeakerIntegration
///
/// The voices are macOS's own, so the test carries no audio. Synthetic
/// voices are easier to tell apart than people on a call are: this proves
/// the models install, load from Clio's folder without the network, and
/// that spans come back on the meeting's clock — not how well it does on a
/// real call.
private let speakerIntegrationEnabled = ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil

@Suite("SpeakerIntegration", .enabled(if: speakerIntegrationEnabled), .serialized)
struct SpeakerIntegrationTests {

    private var modelRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-integration-models", isDirectory: true)
    }

    private func installModels() async throws -> InstalledModel {
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let model = try #require(ModelCatalog.builtIn.first { $0.id == ModelCatalog.speakerModelID })
        let manager = await ModelManager(transport: HuggingFaceTransport(),
                                         modelsDirectory: modelRoot,
                                         huggingFaceCache: URL(fileURLWithPath: "/nonexistent"))
        if await !manager.isInstalled(model.id) {
            await manager.download(model)
            let deadline = ContinuousClock.now + .seconds(300)
            while await !manager.isInstalled(model.id) {
                if let failure = await manager.failures[model.id] {
                    Issue.record("download failed: \(failure)")
                    break
                }
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let installed = try #require(await manager.installed.first { $0.id == model.id })
        print("[speakers] models: \(installed.sizeBytes / 1_000_000) MB at \(installed.url.path), kind \(installed.kind)")
        return installed
    }

    private func say(_ text: String, voice: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-speaker-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", file.path, text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "say has no voice named \(voice)")
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    @Test("Two voices taking turns come back as two speakers, each turn on its own")
    func tellsTwoVoicesApart() async throws {
        let models = try await installModels()
        #expect(models.kind == .speaker)
        #expect(SpeakerModels.isInstalled(at: models.url))

        // A call: forty seconds before anyone speaks, then eight turns —
        // or CLIO_SPEAKER_LEAD seconds and CLIO_SPEAKER_ROUNDS times eight.
        let script: [(voice: String, text: String)] = [
            ("Daniel", "Good morning everyone. Let's start with the beta. The build is ready and I would like to send it to testers on Thursday."),
            ("Karen", "Thursday works for me. I will write the release notes by Wednesday, and I can also update the website."),
            ("Daniel", "Great. Next is the pricing page. The copy is drafted and design is reviewing the table this week."),
            ("Karen", "Let's ship the page the week after the beta. I will do the final pass on Friday morning."),
            ("Daniel", "One more thing about the budget. We spent less than planned on infrastructure this quarter, so there is room for the new hire."),
            ("Karen", "That is good news. I spoke with two candidates last week and both of them could start in January."),
            ("Daniel", "Then let's schedule the second interviews for next week. Can you send me the calendar invitations today?"),
            ("Karen", "Yes, I will send them this afternoon, and I will include the notes from the first conversations."),
        ]
        let rounds = ProcessInfo.processInfo.environment["CLIO_SPEAKER_ROUNDS"].flatMap(Int.init) ?? 1
        let turns = Array(repeating: script, count: rounds).flatMap { $0 }
        let rate = AudioRecorder.sampleRate
        let recording = try StreamRecording()
        defer { recording.discard() }
        var expected: [(voice: String, start: Double, end: Double)] = []
        var clock = ProcessInfo.processInfo.environment["CLIO_SPEAKER_LEAD"].flatMap(Double.init) ?? 40.0
        // Zeros, as the recording has wherever the tap sent nothing. The
        // diarizer is what must cope with them; see withoutDigitalSilence.
        recording.appendSilence(samples: Int(clock * rate))
        for turn in turns {
            let samples = try say(turn.text, voice: turn.voice)
            recording.append(samples)
            let length = Double(samples.count) / rate
            expected.append((turn.voice, clock, clock + length))
            clock += length
            recording.appendSilence(samples: Int(0.7 * rate))
            clock += 0.7
        }
        recording.close()

        let diarizer = SpeakerDiarizer(folder: models.url)
        let began = Date()
        let diarization = try await diarizer.diarize(recording: recording.url)
        let elapsed = Date().timeIntervalSince(began)
        for span in diarization.spans {
            print(String(format: "[speakers] voice %d  %.1f–%.1f", span.speaker, span.start, span.end))
        }
        print(String(format: "[speakers] %.0f s of audio in %.1f s; voiceprints: %@", clock, elapsed,
                     diarization.voiceprints.mapValues(\.count).description))

        // The turns as the transcript would have them, and who they go to.
        let lines = expected.map {
            MeetingLine(speaker: .others, start: $0.start, end: $0.end, text: $0.voice)
        }
        let assignment = SpeakerAssignment.assign(lines: lines, diarization: diarization)
        let voices = lines.map { assignment[$0.id] }
        print("[speakers] turns " + expected.map { String($0.voice.prefix(1)) }.joined()
              + " → " + voices.map { $0.map(String.init) ?? "-" }.joined())
        let ids = diarization.voiceprints.keys.sorted()
        for (index, a) in ids.enumerated() {
            for b in ids[(index + 1)...] {
                print(String(format: "[speakers] distance %d–%d: %.2f", a, b,
                             VoiceprintMath.distance(diarization.voiceprints[a]!, diarization.voiceprints[b]!)))
            }
        }
        print("[speakers] speaking: \(diarization.speakingSeconds.mapValues { Int($0) })")
        #expect(voices == turns.map { $0.voice == "Daniel" ? 1 : 2 })
        #expect(Set(diarization.spans.map(\.speaker)).count == 2)
        // Nothing found in the forty seconds before anyone spoke.
        #expect(diarization.spans.allSatisfy { $0.start > expected[0].start - 1 })
        #expect(diarization.voiceprints.values.allSatisfy { $0.count == 256 })
    }

    /// What telling the voices apart costs at the length of a real meeting:
    /// the whole call is in memory at once for it.
    ///
    ///     CLIO_SPEAKER_MINUTES=60 CLIO_INTEGRATION=1 swift test --filter SpeakerIntegration/aLongCall
    @Test("An hour of call is told apart in a fraction of the hour; this is the time and the memory",
          .enabled(if: ProcessInfo.processInfo.environment["CLIO_SPEAKER_MINUTES"] != nil))
    func aLongCall() async throws {
        let minutes = try #require(ProcessInfo.processInfo.environment["CLIO_SPEAKER_MINUTES"].flatMap(Double.init))
        let models = try await installModels()
        let daniel = try say("The build is ready and I would like to send it to testers on Thursday. Design is reviewing the table this week, and we spent less than planned on infrastructure.", voice: "Daniel")
        let karen = try say("Thursday works for me. I will write the release notes by Wednesday, and I will do the final pass on the pricing page on Friday morning.", voice: "Karen")
        let rate = AudioRecorder.sampleRate
        let recording = try StreamRecording()
        defer { recording.discard() }
        var written = 0
        var turn = 0
        while Double(written) / rate < minutes * 60 {
            let samples = turn.isMultiple(of: 2) ? daniel : karen
            recording.append(samples)
            // A third of the call is nobody talking.
            let pause = samples.count / 2
            recording.appendSilence(samples: pause)
            written += samples.count + pause
            turn += 1
        }
        recording.close()

        func resident() -> Double { Double(ProcessMemory.footprint ?? 0) / 1_048_576 }
        let before = resident()
        let sampler = Task {
            var most = 0.0
            while !Task.isCancelled {
                most = max(most, resident())
                try? await Task.sleep(for: .milliseconds(50))
            }
            return most
        }
        let began = Date()
        let diarization = try await SpeakerDiarizer(folder: models.url).diarize(recording: recording.url)
        let elapsed = Date().timeIntervalSince(began)
        sampler.cancel()
        let peak = await sampler.value
        try await Task.sleep(for: .seconds(1))
        let report = String(
            format: "[speakers] %.0f min of call (%d turns): told apart in %.1f s; %d voices, %d spans; "
                + "memory %.0f MB before, %.0f MB at its peak, %.0f MB after",
            minutes, turn, elapsed, Set(diarization.spans.map(\.speaker)).count, diarization.spans.count,
            before, peak, resident())
        print(report)
        FileHandle.standardError.write(Data((report + "\n").utf8))
        #expect(Set(diarization.spans.map(\.speaker)).count == 2)
        #expect(elapsed < minutes * 60 / 10)

        // Again, in the same process: what is left after the first is kept
        // by the allocator, or lost for good?
        _ = try await SpeakerDiarizer(folder: models.url).diarize(recording: recording.url)
        try await Task.sleep(for: .seconds(1))
        let again = String(format: "[speakers] a second time: %.0f MB after", resident())
        print(again)
        FileHandle.standardError.write(Data((again + "\n").utf8))
    }

    @Test("A recording of nothing has no voices, and needs no model to say so")
    func silenceHasNoVoices() async throws {
        let models = try await installModels()
        let recording = try StreamRecording()
        defer { recording.discard() }
        recording.appendSilence(samples: 16_000 * 30)
        recording.close()
        let diarization = try await SpeakerDiarizer(folder: models.url).diarize(recording: recording.url)
        #expect(diarization.spans.isEmpty)
    }

    // MARK: A whole call

    private final class Source: MeetingAudioSource, @unchecked Sendable {
        var onSamples: (@Sendable ([Float]) -> Void)?
        var hasHeardSound = true
        func start() throws {}
        func stop() {}
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// Everything real but the hardware: a session, Whisper, the speaker
    /// models, and — where one is installed — a summary model to name the
    /// voices and write the notes. Uses the speech and summary models in
    /// Clio's own folder and downloads neither.
    @Test("A call with two other people comes out as a transcript that says who spoke")
    @MainActor
    func aWholeCall() async throws {
        let speakers = try await installModels()
        let manager = ModelManager()
        let speech = try #require(manager.installed(.speech).max { $0.sizeBytes < $1.sizeBytes },
                                  "No speech model installed to test with")
        let language = manager.installed(.language).first?.weightsFile
            .map { LocalSummaryModel(file: $0) }

        // (who, voice, what). The names are said the way they are on calls.
        let script: [(String, String, String)] = [
            ("me", "Fred", "Good morning. Thanks for joining. Daniel, do you want to start with the beta?"),
            ("Daniel", "Daniel", "Sure. The build is ready, and I would like to send it to testers on Thursday."),
            ("Karen", "Karen", "Hi everyone, this is Karen from marketing. Thursday works. I will write the release notes by Wednesday."),
            ("me", "Fred", "Great. What about the pricing page?"),
            ("Daniel", "Daniel", "The copy is drafted, and design is reviewing the table this week."),
            ("Karen", "Karen", "Let's ship the page the week after the beta. I will do the final pass on Friday."),
            ("me", "Fred", "Thanks Karen. Anything else?"),
            ("Daniel", "Daniel", "One more thing. We spent less than planned on infrastructure, so there is room for the new hire."),
        ]

        let mic = Source(), system = Source(), clock = Clock()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-call-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = MeetingSession(
            title: "Weekly sync", folder: folder,
            queue: TranscriptionQueue(WhisperKitEngine()), model: speech,
            options: TranscribeOptions(language: "en"), sensitivity: 0.5, micDeviceUID: nil,
            microphone: mic, systemAudio: system, now: { clock.now() })
        session.diarizer = SpeakerDiarizer(folder: speakers.url)
        if ProcessInfo.processInfo.environment["CLIO_SPEAKER_INVITED"] != nil {
            session.apply(MeetingEvent(
                id: "e", title: "Weekly sync", start: clock.now(), end: clock.now().addingTimeInterval(1800),
                attendees: [MeetingAttendee(name: "Daniel Lee"), MeetingAttendee(name: "Karen Holt"),
                            MeetingAttendee(name: "Priya Shah")]))
        }
        if let language {
            session.nameVoices = { await SpeakerNamer.names(for: $0, with: language) }
            session.summarize = { await MeetingSummarizer.summarize($0, with: language) }
        }
        await session.start()

        func push(_ samples: [Float], to source: Source) {
            var index = 0
            while index < samples.count {
                let end = min(samples.count, index + 1024)
                clock.advance(Double(end - index) / AudioRecorder.sampleRate)
                source.onSamples?(Array(samples[index..<end]))
                index = end
            }
        }
        clock.advance(20)                       // waiting for people to join
        for (who, voice, text) in script {
            push(try say(text, voice: voice), to: who == "me" ? mic : system)
            clock.advance(1.5)                  // nothing is sent between turns
        }
        let began = Date()
        await session.stop()
        print(String(format: "[speakers] stop took %.1f s (drain, voices, names, summary)",
                     Date().timeIntervalSince(began)))
        if let language { await language.unload() }

        let record = session.record
        print("[speakers] file:\n" + (try String(contentsOf: try #require(session.fileURL), encoding: .utf8)))

        func voice(saying word: String) -> Int? {
            record.lines.first { $0.speaker == .others && $0.text.lowercased().contains(word) }?.voice
        }
        let daniel = try #require(voice(saying: "testers"), "Daniel's first line was not put on a voice")
        let karen = try #require(voice(saying: "release notes"), "Karen's first line was not put on a voice")
        #expect(daniel != karen)
        #expect(voice(saying: "drafted") == daniel)
        #expect(voice(saying: "infrastructure") == daniel)
        #expect(voice(saying: "final pass") == karen)
        #expect(record.voiceNumbers.count == 2)
        #expect(record.lines.filter { $0.speaker == .me }.allSatisfy { $0.voice == nil })
        // No audio left anywhere.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: StreamRecording.directory.path)) ?? []
        #expect(left.isEmpty)
        if language != nil {
            // Karen says who she is; Daniel is asked by name and answers.
            #expect(record.voices[karen]?.name.lowercased().contains("karen") == true)
            #expect(record.voices[daniel]?.name.lowercased().contains("daniel") == true)
            print("[speakers] names: \(record.voices.mapValues(\.name))")
        }
    }
}
