import Testing
import Foundation
@testable import ClioCore

private func line(_ speaker: MeetingSpeaker, _ start: Double, _ end: Double,
                  _ text: String = "Something said.", voice: Int? = nil) -> MeetingLine {
    MeetingLine(speaker: speaker, start: start, end: end, text: text, voice: voice)
}

@Suite("Speakers")
struct SpeakerTests {

    // MARK: Lines onto voices

    @Test("A line takes the voice that spoke most of it; voices are numbered in the order they first speak")
    func assigns() {
        let lines = [line(.me, 0, 4), line(.others, 5, 10), line(.others, 11, 20), line(.others, 21, 25)]
        let diarization = Diarization(spans: [
            SpeakerSpan(speaker: 7, start: 5, end: 10),        // the first to speak: Speaker 1
            SpeakerSpan(speaker: 3, start: 11, end: 17),       // most of the second line
            SpeakerSpan(speaker: 7, start: 17, end: 25),       // its end, and all of the third
        ])
        let voices = SpeakerAssignment.assign(lines: lines, diarization: diarization)
        #expect(lines.map { voices[$0.id] } == [nil, 1, 2, 1])
    }

    @Test("A line nobody is heard in stays unassigned, and a voice heard for a moment is not a person")
    func leavesOutWhatIsNotAVoice() {
        let lines = [line(.others, 0, 5), line(.others, 30, 35), line(.others, 50, 55)]
        let diarization = Diarization(spans: [
            SpeakerSpan(speaker: 0, start: 0, end: 5),
            SpeakerSpan(speaker: 1, start: 50, end: 51),       // one second in the whole call
            SpeakerSpan(speaker: 0, start: 51.5, end: 52),
        ])
        let voices = SpeakerAssignment.assign(lines: lines, diarization: diarization)
        #expect(lines.map { voices[$0.id] } == [1, nil, 1])
        #expect(diarization.speakingSeconds == [0: 5.5, 1: 1])
    }

    // MARK: Names

    @Test("A voice is Speaker 2 until it has a name; a guess never replaces a name the user gave")
    func names() {
        var record = MeetingRecord(title: "Sync")
        record.add(line(.me, 0, 1))
        record.add(line(.others, 20, 25, "Hello from the first voice.", voice: 1))
        record.add(line(.others, 60, 65, "And from the second.", voice: 2))
        record.add(line(.others, 100, 105, "Nobody told this one apart."))
        #expect(record.lines.map(record.label(for:)) == ["Me", "Speaker 1", "Speaker 2", "Others"])
        #expect(record.voiceNumbers == [1, 2])

        let changed1 = record.name(voice: 1, as: "Ana Ruiz", confirmed: false)
        #expect(changed1)
        let changed2 = record.name(voice: 2, as: "  Tom\nBerg: ", confirmed: true)
        #expect(changed2)
        #expect(record.lines.map(record.label(for:)) == ["Me", "Ana Ruiz", "Tom Berg", "Others"])
        // A guess over a guess, yes; over the user's, no.
        let changed3 = record.name(voice: 1, as: "Anna", confirmed: false)
        #expect(changed3)
        let changed4 = record.name(voice: 2, as: "Thomas", confirmed: false)
        #expect(!changed4)
        #expect(record.voices[2] == MeetingVoice(name: "Tom Berg", confirmed: true))
        // Taken away again.
        let changed5 = record.name(voice: 2, as: "", confirmed: true)
        #expect(changed5)
        #expect(record.label(for: record.lines[2]) == "Speaker 2")
        // A name that would read back as something else is no name.
        for reserved in ["Me", "others", "Speaker 4", "**"] {
            #expect(MeetingRecord.cleanName(reserved).isEmpty)
        }
        #expect(record.transcriptText.contains("] Anna: Hello from the first voice."))
    }

    @Test("Voices and their names survive the file: who is who, and who said so")
    func roundTrip() throws {
        var record = MeetingRecord(title: "Sync", startDate: Date(timeIntervalSince1970: 1_800_000_000))
        record.add(line(.me, 1, 3, "Hello."))
        record.add(line(.others, 20, 25, "Hi, this is Ana.", voice: 1))
        record.add(line(.others, 26, 30, "And I am somebody else.", voice: 2))   // close, but another voice
        record.add(line(.others, 60, 65, "Me again.", voice: 1))
        record.add(line(.others, 90, 95, "Never told apart."))
        record.name(voice: 1, as: "Ana Ruiz", confirmed: false)

        let text = MeetingMarkdown.render(record)
        #expect(text.contains("speaker-1-guess: Ana Ruiz\n"))
        #expect(text.contains("**[00:20] Ana Ruiz:** Hi, this is Ana."))
        #expect(text.contains("**[00:26] Speaker 2:** And I am somebody else."))
        #expect(text.contains("**[01:30] Others:** Never told apart."))

        var read = try #require(MeetingMarkdown.parse(text))
        #expect(read.lines.map(\.voice) == [nil, 1, 2, 1, nil])
        #expect(read.voices == [1: MeetingVoice(name: "Ana Ruiz", confirmed: false)])

        // Named by hand in the library, and read back as the user's.
        read.name(voice: 2, as: "Tom", confirmed: true)
        let again = try #require(MeetingMarkdown.parse(MeetingMarkdown.render(read)))
        #expect(again.voices[2] == MeetingVoice(name: "Tom", confirmed: true))
        #expect(again.lines.map(again.label(for:)) == ["Me", "Ana Ruiz", "Tom", "Ana Ruiz", "Others"])
    }

    @Test("A file written before there were voices reads back as it always did")
    func oldFiles() throws {
        let old = """
            ---
            clio: 1
            start: 2026-11-02T14:00:00Z
            ---

            # Sync

            ## Transcript

            **[00:01] Me:** Hello.

            **[00:20] Others:** Hi there.
            """
        let record = try #require(MeetingMarkdown.parse(old))
        #expect(record.lines.map(\.voice) == [nil, nil])
        #expect(record.voices.isEmpty)
        #expect(MeetingMarkdown.render(record).contains("**[00:20] Others:** Hi there."))
        #expect(!MeetingMarkdown.render(record).contains("speaker-"))
    }

    // MARK: The namer

    @Test("The namer's answer is read strictly: real voices, real names, and no name twice")
    func parsesNames() {
        let voices: Set<Int> = [1, 2, 3]
        #expect(SpeakerNamer.parse("1 | Ana Ruiz\nSpeaker 2 | **Tom**", voices: voices)
                == [1: "Ana Ruiz", 2: "Tom"])
        #expect(SpeakerNamer.parse("none", voices: voices).isEmpty)
        #expect(SpeakerNamer.parse("1 | Unknown\n2 | none\n9 | Zoe\n3 | ?", voices: voices).isEmpty)
        // One name for two voices is wrong about at least one of them.
        #expect(SpeakerNamer.parse("1 | Ana\n2 | ana\n3 | Tom", voices: voices) == [3: "Tom"])
        #expect(SpeakerNamer.parse("Here you go:\n1 | Ana\nHope that helps!", voices: voices) == [1: "Ana"])
    }

    @Test("The namer is asked about numbers, not earlier guesses, and only when a voice has no name of the user's")
    func asksAboutNumbers() async {
        final class Model: SummaryLanguageModel, @unchecked Sendable {
            let pieceLimit = 5_000
            var prompts: [String] = []
            func respond(instructions: String, prompt: String) async throws -> String {
                prompts.append(prompt)
                return "<think>…</think>\n1 | Ana Ruiz\n2 | Zoe"
            }
        }
        var record = MeetingRecord(title: "Sync")
        record.attendees = [MeetingAttendee(name: "Ana Ruiz"), MeetingAttendee(name: "tom@example.com")]
        record.add(line(.others, 20, 25, "Hi, this is Ana.", voice: 1))
        record.add(line(.others, 60, 65, "Morning.", voice: 2))
        record.name(voice: 1, as: "Wrong Guess", confirmed: false)
        record.name(voice: 2, as: "Tom", confirmed: true)

        let model = Model()
        let names = await SpeakerNamer.names(for: record, with: model)
        #expect(names == [1: "Ana Ruiz"])                       // 2 is the user's: not asked, not taken
        #expect(model.prompts[0].hasPrefix("Invited: Ana Ruiz\n\nTranscript:\n"))
        #expect(model.prompts[0].contains("Speaker 1: Hi, this is Ana."))
        #expect(model.prompts[0].contains("Tom: Morning."))
        #expect(!model.prompts[0].contains("Wrong Guess"))

        record.name(voice: 1, as: "Ana", confirmed: true)
        #expect(await SpeakerNamer.names(for: record, with: model).isEmpty)
        #expect(model.prompts.count == 1)
    }

    // MARK: The recording

    @Test("A recording reads back what was written, silence in its place")
    func recordingRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clio-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = try StreamRecording(directory: folder)
        recording.appendSilence(samples: 40_000)
        recording.append([0.5, -0.5, 2, -2])
        recording.close()
        #expect(recording.isComplete)
        let samples = try StreamRecording.samples(at: recording.url)
        #expect(samples.count == 40_004)
        #expect(samples.prefix(40_000).allSatisfy { $0 == 0 })
        #expect(abs(samples[40_000] - 0.5) < 0.001 && abs(samples[40_001] + 0.5) < 0.001)
        #expect(samples[40_002] == 1 && samples[40_003] == -1)      // clipped, not wrapped
        recording.discard()
        #expect(!FileManager.default.fileExists(atPath: recording.url.path))
    }

    @Test("At launch, what a copy of Clio that is gone left behind is removed; a running copy's is not")
    func leftovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clio-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["111", "222", "stray"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("a.pcm"))
        }
        StreamRecording.removeLeftovers(in: root, isRunning: { $0 == 222 })
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left == ["222"])
    }

    // MARK: Before the model sees it

    @Test("Digital silence becomes quiet noise, and the end is filled out to a whole window; sound is untouched")
    func noDigitalSilence() {
        let input = [Float](repeating: 0, count: 1_000) + [0.25, -0.25] + [Float](repeating: 0, count: 500)
        let output = SpeakerDiarizer.withoutDigitalSilence(input)
        #expect(output.count == SpeakerDiarizer.windowSamples)
        #expect(output[1_000] == 0.25 && output[1_001] == -0.25)
        #expect(!output.contains(0))
        let noise = output[..<1_000] + output[1_002...]
        #expect(noise.allSatisfy { abs($0) <= SpeakerDiarizer.noiseAmplitude })
        // One recording, one answer.
        #expect(SpeakerDiarizer.withoutDigitalSilence(input) == output)
        // Already a whole window: nothing added.
        let whole = [Float](repeating: 0.1, count: SpeakerDiarizer.windowSamples)
        #expect(SpeakerDiarizer.withoutDigitalSilence(whole) == whole)
    }

    @Test("Voiceprints are compared by direction, from 0 to 2; no voice at all is close to nothing")
    func distances() {
        #expect(VoiceprintMath.distance([1, 0], [5, 0]) == 0)
        #expect(VoiceprintMath.distance([1, 0], [0, 3]) == 1)
        #expect(VoiceprintMath.distance([1, 0], [-2, 0]) == 2)
        #expect(VoiceprintMath.distance([0, 0], [1, 0]) == 2)
        #expect(VoiceprintMath.distance([1], [1, 0]) == 2)
    }

    // MARK: The models on disk

    @Test("The speaker models are a kind of their own, installed only once every one of them is whole")
    @MainActor
    func speakerModelsOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clio-speakers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(ModelCatalog.speakerModelID)
        func add(_ path: String) throws {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: file)
        }
        let weights = SpeakerModels.required.flatMap { info in
            (SpeakerModels.compiledModels[info.name] ?? []).map { name in
                String(info.modelURL(baseURL: URL(fileURLWithPath: "/")).path.dropFirst())
                    + "/\(name).mlmodelc/weights/weight.bin"
            }
        }
        #expect(weights.count == 4)
        for path in weights.dropLast() { try add(path) }
        let manager = ModelManager(modelsDirectory: root, huggingFaceCache: URL(fileURLWithPath: "/nonexistent"))
        #expect(!SpeakerModels.isInstalled(at: folder))
        #expect(manager.installed.isEmpty)                       // one model short: not installed

        try add(weights.last!)
        manager.refreshInstalled()
        #expect(SpeakerModels.isInstalled(at: folder))
        #expect(manager.installed.map(\.kind) == [.speaker])
        #expect(manager.installed(.speech).isEmpty)              // never offered to WhisperKit
        #expect(manager.installed(.language).isEmpty)

        // What is taken from the repo: this Mac's variants, not every one.
        #expect(weights.allSatisfy(SpeakerModels.wants(path:)))
        #expect(!SpeakerModels.wants(path: "speaker_embedder/pyannote-v3/W16A16/SpeakerEmbedder.mlmodelc/model.mil"))
        #expect(!SpeakerModels.wants(path: "README.md"))
    }
}
