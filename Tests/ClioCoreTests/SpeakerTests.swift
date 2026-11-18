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

    @Test("A line two voices spoke in becomes a line each, cut where the model's own pieces change hands")
    func splits() {
        typealias Piece = MeetingLine.Piece
        let shared = MeetingLine(
            speaker: .others, start: 10, end: 22, text: "Shall we ship on Thursday? Yes. Thursday works for me. Good.",
            pieces: [Piece(start: 10, end: 13, text: "Shall we ship on Thursday?"),
                     Piece(start: 13.2, end: 13.6, text: "Yes."),            // too short to be heard in: goes with what is before it
                     Piece(start: 14, end: 18, text: "Thursday works for me."),
                     Piece(start: 18.2, end: 22, text: "Good. Then that is settled.")])
        let whole = line(.others, 30, 40, "Nothing to divide here.")
        let mine = MeetingLine(speaker: .me, start: 50, end: 60, text: "Mine.",
                               pieces: [Piece(start: 50, end: 55, text: "Mine."), Piece(start: 55, end: 60, text: "Still mine.")])
        let diarization = Diarization(spans: [
            SpeakerSpan(speaker: 4, start: 10, end: 13.5),
            SpeakerSpan(speaker: 9, start: 13.9, end: 18),
            SpeakerSpan(speaker: 4, start: 18.1, end: 22),
            SpeakerSpan(speaker: 4, start: 30, end: 40),
            SpeakerSpan(speaker: 9, start: 50, end: 60),       // heard under "Me": an echo, not a reason to divide
        ])
        let lines = SpeakerAssignment.split(lines: [shared, whole, mine], diarization: diarization)
        #expect(lines.map(\.text) == ["Shall we ship on Thursday? Yes.", "Thursday works for me.",
                                      "Good. Then that is settled.", "Nothing to divide here.", "Mine."])
        #expect(lines.map(\.start) == [10, 14, 18.2, 30, 50])
        #expect(lines[0].id == shared.id && lines[1].id != shared.id)          // the first is still the line it was
        let voices = SpeakerAssignment.assign(lines: lines, diarization: diarization)
        #expect(lines.map { voices[$0.id] } == [1, 2, 1, 1, nil])

        // One voice throughout, or nothing to go on: the line is not touched.
        let alone = Diarization(spans: [SpeakerSpan(speaker: 4, start: 0, end: 60)])
        #expect(SpeakerAssignment.split(lines: [shared], diarization: alone) == [shared])
        #expect(SpeakerAssignment.split(lines: [shared], diarization: Diarization(spans: [])) == [shared])
        // A second of someone else in the middle of a turn is not a turn.
        let cough = Diarization(spans: [SpeakerSpan(speaker: 4, start: 10, end: 13.2),
                                        SpeakerSpan(speaker: 9, start: 13.2, end: 13.6),
                                        SpeakerSpan(speaker: 9, start: 100, end: 110),
                                        SpeakerSpan(speaker: 4, start: 13.6, end: 22)])
        #expect(SpeakerAssignment.split(lines: [shared], diarization: cough) == [shared])
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

    @Test("A summary written before a voice had its name is brought up to date when it gets one")
    func summaryFollowsTheName() {
        var record = MeetingRecord(title: "Sync")
        record.add(line(.others, 20, 25, "I will write the notes.", voice: 2))
        record.add(line(.others, 40, 45, "And I the slides.", voice: 12))
        record.summary = "### Next steps\n- [ ] Notes — Speaker 2\n- [ ] Slides — Speaker 12"
        record.name(voice: 2, as: "Ana Ruiz", confirmed: true)
        // Speaker 12 is not Speaker 2 with a 1 in front.
        #expect(record.summary == "### Next steps\n- [ ] Notes — Ana Ruiz\n- [ ] Slides — Speaker 12")
        record.name(voice: 2, as: "Ana", confirmed: true)
        #expect(record.summary?.contains("Notes — Ana\n") == true)
        record.name(voice: 2, as: "", confirmed: true)
        #expect(record.summary?.contains("Notes — Speaker 2\n") == true)
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

    // MARK: The invitation

    /// The call this was written for: three invited by address alone, one
    /// of them recording.
    private var threeInvited: [MeetingAttendee] {
        [MeetingAttendee(name: "claire.rumore@example.com", email: "claire.rumore@example.com"),
         MeetingAttendee(name: "lukasz@example.com", email: "lukasz@example.com"),
         MeetingAttendee(name: "bart@example.com", email: "bart@example.com", isMe: true)]
    }

    @Test("A roster is those invited less whoever records, named from an address when that is all there is")
    func roster() {
        let roster = SpeakerRoster(attendees: threeInvited + [MeetingAttendee(name: "Tom Berg", declined: true)])
        #expect(roster.me == "Bart")
        #expect(roster.others == ["Claire Rumore", "Lukasz"])
        #expect(MeetingAttendee(name: "ana+work", email: "ana+work@example.com").personName == "Ana")
        #expect(MeetingAttendee(name: "Ana Ruiz", email: "a@example.com").personName == "Ana Ruiz")
        #expect(MeetingAttendee(name: "1234@example.com").personName == nil)

        #expect(roster.person(named: "Claire") == .other(0))
        #expect(roster.person(named: "Łukasz") == .other(1))
        #expect(roster.person(named: "bart") == .me)
        #expect(roster.person(named: "Thomas") == .nobody)
        let twoAnas = SpeakerRoster(me: "Bo", others: ["Ana Ruiz", "Ana Lee"])
        #expect(twoAnas.person(named: "Ana") == .unclear)
        #expect(twoAnas.person(named: "Ana Lee") == .other(1))
    }

    @Test("A guess is held to the invitation: never whoever records, nobody uninvited, and the last voice is the last person")
    func settles() {
        let roster = SpeakerRoster(attendees: threeInvited)
        // What the model said of that call, once its third voice was folded.
        #expect(roster.settle([1: "Claire", 2: "Bart"], voices: [1, 2])
                == [1: "Claire Rumore", 2: "Lukasz"])
        // Unfolded: three voices for two people, so someone uninvited may
        // be there and "Thomas" is allowed — but "Bart" still is not, and
        // nothing follows by elimination.
        #expect(roster.settle([1: "Claire", 2: "Bart", 3: "Thomas"], voices: [1, 2, 3])
                == [1: "Claire Rumore", 3: "Thomas"])
        // No more voices than people: a name from outside was only talked about.
        #expect(roster.settle([1: "Thomas"], voices: [1]).isEmpty)
        // One person for two voices is wrong about one of them; with both
        // left out, nothing is left to eliminate with.
        #expect(roster.settle([1: "Claire", 2: "Claire Rumore"], voices: [1, 2]).isEmpty)
        // A name that stands is not guessed again, and leaves one of each.
        #expect(roster.settle([2: "Claire"], known: [1: "Claire"], voices: [1, 2]) == [2: "Lukasz"])
        // A name that stands for somebody not invited: two people free, one voice.
        #expect(roster.settle([:], known: [1: "Zoe"], voices: [1, 2]).isEmpty)
        // Fewer voices than people: whoever is missing is not known.
        #expect(roster.settle([:], voices: [1]).isEmpty)

        // Not known who records: their name cannot be ruled out, and
        // nothing is eliminated — the list has one person too many.
        let unknown = SpeakerRoster(others: ["Claire", "Lukasz"])
        #expect(unknown.settle([1: "Claire"], voices: [1, 2]) == [1: "Claire"])
        // No invitation at all: the guesses as they came.
        #expect(SpeakerRoster().settle([1: "Ana", 2: "Tom"], voices: [1, 2]) == [1: "Ana", 2: "Tom"])
    }

    @Test("The namer says who Me is, and what it answers is settled against the invitation")
    func namesWithinTheInvitation() async {
        final class Model: SummaryLanguageModel, @unchecked Sendable {
            let pieceLimit = 5_000
            var prompt = ""
            func respond(instructions: String, prompt: String) async throws -> String {
                self.prompt = prompt
                return "1 | Claire\n2 | Bart"
            }
        }
        var record = MeetingRecord(title: "Sync")
        record.attendees = threeInvited
        record.add(line(.others, 20, 25, "Hey, hi.", voice: 1))
        record.add(line(.others, 30, 35, "Good to see you.", voice: 2))
        let model = Model()
        #expect(await SpeakerNamer.names(for: record, with: model) == [1: "Claire Rumore", 2: "Lukasz"])
        #expect(model.prompt.hasPrefix("\"Me\" is: Bart\n\nInvited: Claire Rumore, Lukasz\n\nTranscript:\n"))

        // Who records survives the file.
        let read = MeetingMarkdown.parse(MeetingMarkdown.render(record))
        #expect(read?.attendees == record.attendees)
    }

    @Test("More voices than people invited: one that said little and sounds like another is folded into it")
    func folds() {
        let claire: [Float] = [1, 0, 0], lukasz: [Float] = [0, 1, 0]
        let aside: [Float] = [0.9, 0.3, 0]           // 0.05 from Claire
        let spans = [SpeakerSpan(speaker: 0, start: 0, end: 300),
                     SpeakerSpan(speaker: 1, start: 300, end: 560),
                     SpeakerSpan(speaker: 2, start: 560, end: 580)]
        let heard = Diarization(spans: spans, voiceprints: [0: claire, 1: lukasz, 2: aside])

        let folded = heard.folded(to: 2)
        #expect(folded.spans.map(\.speaker) == [0, 1, 0])
        #expect(folded.voiceprints.keys.sorted() == [0, 1])
        // As many voices as people, or no count: as it was.
        #expect(heard.folded(to: 3) == heard)
        #expect(heard.folded(to: 0) == heard)

        // A voice like neither is a third person, whoever was invited.
        let stranger = Diarization(spans: spans, voiceprints: [0: claire, 1: lukasz, 2: [0, 0, 1]])
        #expect(stranger.folded(to: 2) == stranger)
        // One that spoke as much as the others is no aside.
        var talker = heard
        talker.spans[2].end = 800
        #expect(talker.folded(to: 2) == talker)
        // No print, nothing to compare.
        let silent = Diarization(spans: spans, voiceprints: [0: claire, 1: lukasz])
        #expect(silent.folded(to: 2) == silent)
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
        // An invitation with only an address is still somebody: its words.
        #expect(model.prompts[0].hasPrefix("Invited: Ana Ruiz, Tom\n\nTranscript:\n"))
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

// MARK: - Voices remembered

/// A voiceprint at a chosen distance from [1, 0]: the cosine distance of
/// two unit vectors is one minus the cosine of the angle between them.
private func vector(at distance: Float) -> [Float] {
    let angle = acos(1 - distance)
    return [cos(angle), sin(angle)]
}

private func kept(_ name: String?, meeting: String, at distance: Float, confirmed: Bool = true,
                  seconds: Double = 120, space: String = "s") -> Voiceprint {
    Voiceprint(meeting: meeting, voice: 1, date: Date(timeIntervalSince1970: 0),
               vector: vector(at: distance), seconds: seconds, name: name,
               confirmed: confirmed, space: space)
}

@Suite("Voice memory")
struct VoiceMemoryTests {
    private let sample = VoiceSample(vector: [1, 0], seconds: 300)
    private let matcher = VoiceprintMatcher()

    @Test("A voice heard close by in three meetings, twice confirmed, is that person; fewer is only probable")
    func levels() {
        let ana = [kept("Ana Ruiz", meeting: "a", at: 0.10), kept("Ana Ruiz", meeting: "b", at: 0.15),
                   kept("Ana Ruiz", meeting: "c", at: 0.12, confirmed: false)]
        let high = matcher.match(sample, space: "s", corpus: ana)
        #expect(high?.level == .high)
        #expect(high?.name == "Ana Ruiz")
        #expect(high?.meetings == 3 && high?.confirmedMeetings == 2)
        #expect(abs((high?.distance ?? 9) - 0.10) < 0.001)

        #expect(matcher.match(sample, space: "s", corpus: Array(ana.prefix(2)))?.level == .medium)
        // Near enough to count, too far to be called probable.
        #expect(matcher.match(sample, space: "s", corpus: [kept("Ana Ruiz", meeting: "a", at: 0.40)])?.level == .low)
        // Out of reach, unnamed, or another model's: nothing.
        #expect(matcher.match(sample, space: "s", corpus: [kept("Ana Ruiz", meeting: "a", at: 0.60)]) == nil)
        #expect(matcher.match(sample, space: "s", corpus: [kept(nil, meeting: "a", at: 0.05)]) == nil)
        #expect(matcher.match(sample, space: "other", corpus: ana) == nil)
    }

    @Test("Names a model guessed count for little: many of them are only probable, one is hardly anything")
    func guessesCountLess() {
        let guesses = ["a", "b", "c"].map { kept("Ana Ruiz", meeting: $0, at: 0.10, confirmed: false) }
        #expect(matcher.match(sample, space: "s", corpus: guesses)?.level == .medium)
        #expect(matcher.match(sample, space: "s", corpus: Array(guesses.prefix(1)))?.level == .low)
        // A confirmed someone-else nearby outweighs a pile of guesses.
        let match = matcher.match(sample, space: "s", corpus: guesses + [kept("Tom Berg", meeting: "d", at: 0.12)])
        #expect(match?.name == "Tom Berg")
    }

    @Test("Two people it could be is said as two; an invitation tips it; a few words of speech hardly count")
    func ambiguity() {
        let two = [kept("Ana Ruiz", meeting: "a", at: 0.15), kept("Tom Berg", meeting: "b", at: 0.18)]
        let tie = matcher.match(sample, space: "s", corpus: two)
        #expect(tie?.level == .ambiguous)
        #expect(tie?.names == ["Ana Ruiz", "Tom Berg"])

        // Tom was invited to this one, Ana was not: it is him, though not surely.
        let invited = matcher.match(sample, space: "s", corpus: two, invited: ["Tom Berg"])
        #expect(invited?.names.first == "Tom Berg")

        // Ana's print is from four seconds of speech; Tom's from two minutes.
        let thin = [kept("Ana Ruiz", meeting: "a", at: 0.10, seconds: 4), kept("Tom Berg", meeting: "b", at: 0.18)]
        let match = matcher.match(sample, space: "s", corpus: thin)
        #expect(match?.name == "Tom Berg" && match?.level == .medium)
    }

    @Test("A first name and the full name it begins are one person, unless two full names begin with it")
    func aliases() {
        let people = VoiceprintMatcher.people(["Ana", "Ana Ruiz", "Tom"])
        #expect(people["ana"] == "Ana Ruiz" && people["ana ruiz"] == "Ana Ruiz" && people["tom"] == "Tom")
        let unclear = VoiceprintMatcher.people(["Ana", "Ana Ruiz", "Ana Lee"])
        #expect(unclear["ana"] == "Ana")

        // Typed "Ana" twice and "Ana Ruiz" once: three meetings of one person.
        let corpus = [kept("Ana", meeting: "a", at: 0.10), kept("ana", meeting: "b", at: 0.12),
                      kept("Ana Ruiz", meeting: "c", at: 0.11)]
        let match = matcher.match(sample, space: "s", corpus: corpus)
        #expect(match?.level == .high && match?.name == "Ana Ruiz")
    }

    @Test("An address settles who someone is: names it was seen with are one person, and two people of one name are two")
    func emails() async throws {
        func kept(_ name: String, _ email: String?, meeting: String, at distance: Float) -> Voiceprint {
            Voiceprint(meeting: meeting, voice: 1, date: Date(timeIntervalSince1970: 0),
                       vector: vector(at: distance), seconds: 120, name: name, email: email,
                       confirmed: true, space: "s")
        }
        // "Ana R." and "Ana Ruiz" are no first-name-and-full-name pair; the address says they are one.
        let one = [kept("Ana R.", "ana@example.com", meeting: "a", at: 0.10),
                   kept("Ana Ruiz", "ANA@example.com", meeting: "b", at: 0.12),
                   kept("Ana Ruiz", "ana@example.com", meeting: "c", at: 0.11)]
        let match = matcher.match(sample, space: "s", corpus: one)
        #expect(match?.level == .high && match?.name == "Ana Ruiz" && match?.meetings == 3)
        // Without addresses the same three are two people: two meetings of
        // one, one of the other — probable, and no longer sure.
        let anonymous = one.map { print -> Voiceprint in var copy = print; copy.email = nil; return copy }
        let unsure = matcher.match(sample, space: "s", corpus: anonymous)
        #expect(unsure?.level == .medium && unsure?.meetings == 2)

        // Invited under an address, whatever the invitation calls them this time.
        let two = [kept("Ana Ruiz", "ana@example.com", meeting: "a", at: 0.15),
                   kept("Tom Berg", "tom@example.com", meeting: "b", at: 0.14)]
        #expect(matcher.match(sample, space: "s", corpus: two)?.level == .ambiguous)
        let invited = matcher.match(sample, space: "s", corpus: two, invitedEmails: ["ANA@example.com"])
        #expect(invited?.names.first == "Ana Ruiz")

        // The store takes the address from the invitation, by name — and not when two invited share it.
        let attendees = [MeetingAttendee(name: "Ana Ruiz", email: "ana@example.com"),
                         MeetingAttendee(name: "Tom Berg", email: "tom@example.com"),
                         MeetingAttendee(name: "Tom Hale", email: "hale@example.com")]
        #expect(VoiceMemory.email(for: "ana", in: attendees) == "ana@example.com")
        #expect(VoiceMemory.email(for: "Ana Ruiz", in: attendees) == "ana@example.com")
        #expect(VoiceMemory.email(for: "Tom", in: attendees) == nil)
        #expect(VoiceMemory.email(for: "Zoe", in: attendees) == nil)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-voices-\(UUID().uuidString)/voiceprints.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var record = MeetingRecord(title: "Sync", startDate: Date(timeIntervalSince1970: 1_000))
        record.attendees = attendees
        record.name(voice: 1, as: "Ana", confirmed: true)
        let memory = VoiceMemory(file: file)
        await memory.remember(record, samples: [1: VoiceSample(vector: [1, 0], seconds: 60)], space: "s")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("ana@example.com"))
        // A store written before there were addresses still reads.
        let old = saved.replacingOccurrences(of: "\"email\":\"ana@example.com\",", with: "")
        #expect(!old.contains("email"))
        try Data(old.utf8).write(to: file)
        #expect(await VoiceMemory(file: file).count == 1)
    }

    @Test("Voices are kept with their meeting, follow its names, and go when it does — or all at once")
    func store() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-voices-\(UUID().uuidString)/voiceprints.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        func record(_ start: Double, names: [Int: (String, Bool)]) -> MeetingRecord {
            var record = MeetingRecord(title: "Sync", startDate: Date(timeIntervalSince1970: start))
            for (voice, name) in names { record.name(voice: voice, as: name.0, confirmed: name.1) }
            return record
        }
        let samples = [1: VoiceSample(vector: vector(at: 0.1), seconds: 90),
                       2: VoiceSample(vector: [0, 1], seconds: 30)]
        let memory = VoiceMemory(file: file)
        #expect(await memory.count == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        var first = record(1_000, names: [1: ("Ana Ruiz", true)])
        await memory.remember(first, samples: samples, space: "s")
        await memory.remember(record(2_000, names: [1: ("Ana Ruiz", true)]), samples: samples, space: "s")
        await memory.remember(record(3_000, names: [1: ("Ana", false)]), samples: samples, space: "s")
        // Again, for the same meeting: in place of, not on top of.
        await memory.remember(first, samples: samples, space: "s")
        #expect(await memory.count == 6)
        #expect(await memory.peopleCount == 1)

        // Read by another instance: it is on disk, and the vectors survive.
        let reopened = VoiceMemory(file: file)
        let fourth = record(4_000, names: [:])
        let matches = await reopened.matches(for: [1: VoiceSample(vector: [1, 0], seconds: 60)], space: "s",
                                             meeting: VoiceMemory.key(for: fourth), invited: [])
        #expect(matches[1]?.level == .high && matches[1]?.name == "Ana Ruiz")
        // A meeting is no evidence about itself.
        let own = await reopened.matches(for: [1: samples[1]!], space: "s",
                                         meeting: VoiceMemory.key(for: first), invited: [])
        #expect(own[1]?.meetings == 2)

        // The second voice is named by hand afterwards; the first un-named.
        first.name(voice: 2, as: "Tom", confirmed: true)
        first.name(voice: 1, as: "", confirmed: true)
        await reopened.rename(first)
        #expect(await reopened.peopleCount == 2)
        let after = await reopened.matches(for: [1: VoiceSample(vector: [1, 0], seconds: 60)], space: "s",
                                           meeting: "x", invited: [])
        #expect(after[1]?.level == .medium)                       // one confirmation fewer

        await reopened.forget(meeting: VoiceMemory.key(for: first))
        #expect(await reopened.count == 4)
        let report = await reopened.report()
        #expect(report.contains("4 kept"))
        await reopened.forgetAll()
        #expect(await reopened.count == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("What the voices say is put to the namer in plain words, for the voices it is asked about")
    func hints() {
        var record = MeetingRecord(title: "Sync")
        record.add(line(.others, 20, 25, "Morning.", voice: 1))
        record.add(line(.others, 60, 65, "Hello.", voice: 2))
        let probable = VoiceMatch(level: .medium, names: ["Ana Ruiz"], distance: 0.25, meetings: 2, confirmedMeetings: 1)
        let unclear = VoiceMatch(level: .ambiguous, names: ["Tom Berg", "Tim Burke"], distance: 0.2, meetings: 1, confirmedMeetings: 1)
        let prompt = SpeakerNamer.prompt(for: record, limit: 5_000, matches: [1: probable, 2: unclear])
        #expect(prompt.contains("Voices heard before:\nSpeaker 1: the voice is probably Ana Ruiz's (2 earlier calls)."))
        #expect(prompt.contains("Speaker 2: the voice is like those of Tom Berg and Tim Burke; the conversation has to say which."))
        #expect(prompt.range(of: "Voices heard before")!.lowerBound < prompt.range(of: "Transcript:")!.lowerBound)
        #expect(!SpeakerNamer.prompt(for: record, limit: 5_000).contains("Voices heard before"))
    }
}
