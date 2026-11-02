import Testing
import Foundation
@testable import ClioCore

// MARK: - Segmenting

private let rate = AudioRecorder.sampleRate

private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
}

private func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * rate))
}

/// Feeds a stream in blocks the size a capture delivers, and finishes it.
private func segment(_ stream: [Float], block: Int = 1024) -> [SpeechChunk] {
    var segmenter = SpeechSegmenter()
    var chunks: [SpeechChunk] = []
    var index = 0
    while index < stream.count {
        let end = min(stream.count, index + block)
        chunks += segmenter.append(Array(stream[index..<end]))
        index = end
    }
    return chunks + segmenter.finish()
}

@Suite("Meeting segmenting")
struct SegmentingTests {
    @Test("Two utterances with a long pause between them are two chunks, with their own start times")
    func cutsAtLongPause() {
        let chunks = segment(silence(1) + tone(2) + silence(2) + tone(2) + silence(1))
        #expect(chunks.count == 2)
        #expect(abs(chunks[0].start - 1) < 0.25)
        #expect(abs(chunks[1].start - 5) < 0.25)
        #expect(chunks.allSatisfy { $0.duration < 3 })
    }

    @Test("A short breath does not cut a short utterance in two")
    func keepsShortPause() {
        let chunks = segment(tone(2) + silence(0.8) + tone(1.5) + silence(2))
        #expect(chunks.count == 1)
        #expect(chunks[0].duration > 4)
    }

    @Test("Talking without a pause is cut before Whisper's 30-second window, and nothing is lost")
    func capsLongSpeech() {
        let stream = tone(70)
        let chunks = segment(stream)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.duration <= 25.01 })
        #expect(chunks.map(\.samples.count).reduce(0, +) == stream.count)
        // Contiguous: each starts where the last ended.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(previous.end - next.start) < 0.001)
        }
    }

    @Test("Silence produces nothing")
    func silenceIsDropped() {
        #expect(segment(silence(40)).isEmpty)
    }

    @Test("The block size the hardware delivers in does not change the chunks")
    func blockSizeIndependent() {
        let stream = silence(0.5) + tone(3) + silence(2) + tone(5) + silence(0.3)
        let a = segment(stream, block: 1024)
        let b = segment(stream, block: 333)
        #expect(a.map(\.start) == b.map(\.start))
        #expect(a.map(\.samples.count) == b.map(\.samples.count))
    }

    @Test("A gap with no samples at all ends the speech and keeps the clock: the next chunk starts when it was said")
    func skipKeepsTime() {
        var segmenter = SpeechSegmenter()
        var chunks = segmenter.append(silence(1) + tone(2))
        chunks += segmenter.skip(Int(600 * rate))          // ten silent minutes, not in memory
        chunks += segmenter.append(tone(2) + silence(2))
        chunks += segmenter.finish()
        #expect(chunks.count == 2)
        #expect(abs(chunks[0].start - 1) < 0.25)
        #expect(abs(chunks[1].start - 603) < 0.25)
    }

    @Test("Speech still going at the end of the meeting is handed over by finish")
    func finishFlushes() {
        let chunks = segment(silence(1) + tone(3))
        #expect(chunks.count == 1)
        #expect(chunks[0].duration > 2.9)
    }
}

// MARK: - Sharing the engine

/// Records the order jobs ran in, and whether two ever overlapped.
private actor OrderEngine: TranscriptionEngine {
    private(set) var order: [String] = []
    private(set) var overlapped = false
    private var running = 0

    var isLoaded: Bool { true }
    func load(model: InstalledModel) async throws {}
    func unload() async {}

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript {
        running += 1
        if running > 1 { overlapped = true }
        try await Task.sleep(for: .milliseconds(40))
        order.append(options.initialPrompt ?? "?")
        running -= 1
        return Transcript(text: options.initialPrompt ?? "")
    }
}

@Suite("Transcription queue")
struct TranscriptionQueueTests {
    @Test("Jobs never overlap, and a dictation goes ahead of meeting chunks that are waiting")
    func dictationJumpsTheQueue() async throws {
        let engine = OrderEngine()
        let queue = TranscriptionQueue(engine)

        func job(_ name: String, _ priority: TranscriptionPriority) -> Task<Void, Never> {
            Task {
                _ = try? await queue.transcribe(samples: [0],
                                                options: TranscribeOptions(initialPrompt: name),
                                                priority: priority)
            }
        }

        let first = job("m1", .meeting)
        try await Task.sleep(for: .milliseconds(10))   // m1 is running
        let m2 = job("m2", .meeting)
        try await Task.sleep(for: .milliseconds(5))
        let m3 = job("m3", .meeting)
        try await Task.sleep(for: .milliseconds(5))
        let d = job("d", .dictation)
        for task in [first, m2, m3, d] { await task.value }

        #expect(await engine.order == ["m1", "d", "m2", "m3"])
        #expect(await engine.overlapped == false)
    }
}

// MARK: - The record

@Suite("Meeting record")
struct MeetingRecordTests {
    private func line(_ speaker: MeetingSpeaker, _ start: TimeInterval, _ text: String,
                      length: TimeInterval = 4) -> MeetingLine {
        MeetingLine(speaker: speaker, start: start, end: start + length, text: text)
    }

    @Test("Lines land in the order they were said, whichever was transcribed first")
    func ordersByTime() {
        var record = MeetingRecord(title: "Sync")
        record.add(line(.others, 20, "Second thing."))
        record.add(line(.me, 5, "First thing."))
        record.add(line(.others, 40, "Third thing."))
        #expect(record.lines.map(\.text) == ["First thing.", "Second thing.", "Third thing."])
    }

    @Test("The microphone hearing the call through speakers is not attributed to me — either order")
    func dropsEcho() {
        let theirs = line(.others, 10, "We should ship the release on Thursday afternoon.")
        let echo = line(.me, 10.4, "we should ship the release on thursday afternoon")

        var echoSecond = MeetingRecord(title: "A")
        echoSecond.add(theirs)
        let added = echoSecond.add(echo)
        #expect(added == false)
        #expect(echoSecond.lines.count == 1)

        var echoFirst = MeetingRecord(title: "B")
        echoFirst.add(echo)
        echoFirst.add(theirs)
        #expect(echoFirst.lines.map(\.speaker) == [.others])
    }

    @Test("Agreeing out loud is not an echo: different words, or a different moment")
    func keepsRealReplies() {
        var record = MeetingRecord(title: "C")
        record.add(line(.others, 10, "We should ship the release on Thursday afternoon."))
        let reply = record.add(line(.me, 15, "Thursday works, I'll write the release notes."))
        let later = record.add(line(.me, 300, "We should ship the release on Thursday afternoon."))
        #expect(reply && later)
        #expect(record.lines.count == 3)
    }

    @Test("The Markdown has the title, attendees, notes and a transcript in turns")
    func rendersMarkdown() {
        var record = MeetingRecord(title: "Weekly sync",
                                   startDate: Date(timeIntervalSince1970: 1_800_000_000))
        record.endDate = record.startDate.addingTimeInterval(1800)
        record.attendees = [MeetingAttendee(name: "Ana"), MeetingAttendee(name: "Bo", declined: true)]
        record.notes = "- ship it"
        record.add(line(.me, 1, "Hello."))
        record.add(line(.me, 5.5, "Can you hear me?"))
        record.add(line(.others, 12, "Yes."))
        record.add(line(.others, 3725, "Bye."))
        let markdown = MeetingMarkdown.render(record)

        #expect(markdown.hasPrefix("# Weekly sync\n"))
        #expect(markdown.contains("**Attendees:** Ana, Bo (declined)"))
        #expect(markdown.contains("## Notes\n\n- ship it"))
        #expect(markdown.contains("**[00:01] Me:** Hello. Can you hear me?"))
        #expect(markdown.contains("**[00:12] Others:** Yes."))
        #expect(markdown.contains("**[1:02:05] Others:** Bye."))
        #expect(!markdown.contains("## Summary"))
    }

    @Test("File names sort by date and survive any title")
    func fileNames() {
        let record = MeetingRecord(title: "Q3: plan / budget?",
                                   startDate: Date(timeIntervalSince1970: 1_800_000_000))
        let name = MeetingMarkdown.fileName(for: record)
        #expect(name.hasSuffix(".md"))
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("?"))
        #expect(name.hasPrefix("20"))
    }

    @Test("Writing again after a rename leaves one file")
    func rewriteReplaces() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = MeetingRecord(title: "Zoom")
        let first = try MeetingMarkdown.write(record, to: folder)
        record.title = "Design review"
        let second = try MeetingMarkdown.write(record, to: folder, replacing: first)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == [second.lastPathComponent])
    }
}

// MARK: - Calendar

@Suite("Meeting calendar")
struct MeetingCalendarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, from start: TimeInterval, to end: TimeInterval,
                       allDay: Bool = false, declined: Bool = false,
                       people: Int = 2, link: Bool = false) -> MeetingEvent {
        MeetingEvent(id: id, title: id,
                     start: now.addingTimeInterval(start * 60),
                     end: now.addingTimeInterval(end * 60),
                     isAllDay: allDay,
                     attendees: (0..<people).map { MeetingAttendee(name: "P\($0)") },
                     joinURL: link ? URL(string: "https://zoom.us/j/1") : nil,
                     declinedByMe: declined)
    }

    @Test("The meeting on now is the one picked; all-day and declined ones never are")
    func picksCurrent() {
        let events = [event("allday", from: -600, to: 600, allDay: true),
                      event("declined", from: -10, to: 20, declined: true),
                      event("standup", from: -10, to: 20)]
        #expect(MeetingEventMatching.current(in: events, at: now)?.id == "standup")
    }

    @Test("A meeting started a few minutes early still counts as its event, but not one an hour away")
    func earlyStart() {
        #expect(MeetingEventMatching.current(in: [event("soon", from: 3, to: 30)], at: now)?.id == "soon")
        #expect(MeetingEventMatching.current(in: [event("later", from: 60, to: 90)], at: now) == nil)
    }

    @Test("Of two overlapping events, a call beats a block of time, then the later start wins")
    func prefersCalls() {
        let block = event("focus", from: -30, to: 60, people: 0)
        let call = event("1:1", from: -40, to: 30, people: 2)
        #expect(MeetingEventMatching.current(in: [block, call], at: now)?.id == "1:1")

        let leaving = event("old", from: -60, to: 2, link: true)
        let joining = event("new", from: -1, to: 30, link: true)
        #expect(MeetingEventMatching.current(in: [leaving, joining], at: now)?.id == "new")
    }

    @Test("The join link is found in the URL, the location or the notes, and the calendar's own page is not one")
    func findsJoinLink() {
        let zoom = URL(string: "https://acme.zoom.us/j/123?pwd=x")!
        #expect(MeetingEventMatching.joinURL(url: zoom, location: nil, notes: nil) == zoom)
        #expect(MeetingEventMatching.joinURL(
            url: URL(string: "https://calendar.google.com/event?eid=1"),
            location: "Room 4", notes: "Join: https://meet.google.com/abc-defg-hij thanks")?
            .host == "meet.google.com")
        #expect(MeetingEventMatching.joinURL(url: nil, location: "Café", notes: "bring snacks") == nil)
    }

    @Test("Upcoming is today's events still to come, soonest first")
    func upcoming() {
        let events = [event("c", from: 120, to: 150), event("past", from: -90, to: -30),
                      event("a", from: -5, to: 25), event("b", from: 60, to: 90)]
        #expect(MeetingEventMatching.upcoming(in: events, at: now).map(\.id) == ["a", "b", "c"])
    }
}

@Suite("Meeting summary")
struct MeetingSummaryTests {
    @Test("A long transcript is split at line breaks into pieces the model can hold")
    func splitsIntoPieces() {
        let line = String(repeating: "word ", count: 40)   // 200 characters
        let text = Array(repeating: line, count: 100).joined(separator: "\n")
        let pieces = MeetingSummarizer.pieces(of: text, limit: 1_000)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 1_000 })
        #expect(pieces.joined(separator: "\n").count == text.count)
    }
}

// MARK: - Noticing calls

@Suite("Call detection")
struct CallDetectionTests {
    private let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false)
    private let chrome = CallApp(bundleID: "com.google.Chrome", name: "Chrome", isBrowser: true)
    private let call = MeetingEvent(id: "e1", title: "Sync", start: Date(), end: Date(),
                                    attendees: [MeetingAttendee(name: "A"), MeetingAttendee(name: "B")])

    @Test("Apps and their helper processes are recognised; anything else is not")
    func classifies() {
        #expect(CallDetection.classify(bundleID: "us.zoom.xos")?.name == "Zoom")
        #expect(CallDetection.classify(bundleID: "us.zoom.xos.helper")?.bundleID == "us.zoom.xos")
        #expect(CallDetection.classify(bundleID: "com.google.Chrome.helper")?.isBrowser == true)
        #expect(CallDetection.classify(bundleID: "com.apple.WebKit.GPU")?.name == "Safari")
        #expect(CallDetection.classify(bundleID: "com.apple.VoiceMemos") == nil)
    }

    @Test("A call app on the microphone is offered once; a browser only during a calendar call")
    func offers() {
        var watch = CallWatch()
        #expect(watch.offer(apps: [chrome], event: nil) == nil)
        #expect(watch.offer(apps: [chrome], event: call) == chrome)
        #expect(watch.offer(apps: [chrome], event: call) == nil)
        #expect(watch.offer(apps: [zoom], event: nil) == zoom)
        #expect(watch.offer(apps: [zoom], event: nil) == nil)
        // The call ends and another begins: offered again.
        #expect(watch.offer(apps: [], event: nil) == nil)
        #expect(watch.offer(apps: [zoom], event: nil) == zoom)
    }

    @Test("A meeting stops after half a minute off the microphone, not at the first gap")
    func stopsWhenCallEnds() {
        var watch = CallWatch()
        watch.meetingStarted()
        for _ in 0..<(CallWatch.quietChecksToStop - 1) {
            #expect(watch.callEnded(app: zoom, apps: []) == false)
        }
        #expect(watch.callEnded(app: zoom, apps: [zoom]) == false)   // back: count resets
        for _ in 0..<(CallWatch.quietChecksToStop - 1) {
            #expect(watch.callEnded(app: zoom, apps: []) == false)
        }
        #expect(watch.callEnded(app: zoom, apps: []) == true)
    }
}
