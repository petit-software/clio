import CoreGraphics
import Testing
import AVFoundation
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
        record.attendees = [MeetingAttendee(name: "Ana", email: "ana@example.com"),
                            MeetingAttendee(name: "Bo", declined: true)]
        record.notes = "- ship it"
        record.add(line(.me, 1, "Hello."))
        record.add(line(.me, 5.5, "Can you hear me?"))
        record.add(line(.others, 12, "Yes."))
        record.add(line(.others, 3725, "Bye."))
        let markdown = MeetingMarkdown.render(record)

        #expect(markdown.hasPrefix("---\nclio: 1\nstart: "))
        #expect(markdown.contains("---\n\n# Weekly sync\n"))
        #expect(markdown.contains("**Attendees:** Ana <ana@example.com>, Bo (declined)"))
        #expect(markdown.contains("## Notes\n\n- ship it"))
        #expect(markdown.contains("**[00:01] Me:** Hello. Can you hear me?"))
        #expect(markdown.contains("**[00:12] Others:** Yes."))
        #expect(markdown.contains("**[1:02:05] Others:** Bye."))
        #expect(!markdown.contains("## Summary"))
    }

    @Test("What is written is what is read back: title, dates, people, link, notes, summary, every line")
    func roundTrips() throws {
        var record = MeetingRecord(title: "Weekly sync: Q3",
                                   startDate: Date(timeIntervalSince1970: 1_800_000_000))
        record.endDate = record.startDate.addingTimeInterval(1800)
        record.attendees = [MeetingAttendee(name: "Ana Ruiz", email: "ana@example.com"),
                            MeetingAttendee(name: "Bo", declined: true, email: "bo@example.com"),
                            MeetingAttendee(name: "Kit")]
        record.joinURL = URL(string: "https://zoom.us/j/123")
        record.notes = "- ship it\n- **bold** idea"
        record.summary = "### Beta\n- Thursday"
        record.add(line(.me, 1, "Hello."))
        record.add(line(.others, 20, "Hi there, everyone."))
        record.add(line(.me, 3725, "Bye now."))

        let read = try #require(MeetingMarkdown.parse(MeetingMarkdown.render(record)))
        #expect(read.title == record.title)
        #expect(read.startDate == record.startDate)
        #expect(read.endDate == record.endDate)
        #expect(read.attendees == record.attendees)
        #expect(read.joinURL == record.joinURL)
        #expect(read.notes == record.notes)
        #expect(read.summary == record.summary)
        #expect(read.lines.map(\.speaker) == [.me, .others, .me])
        #expect(read.lines.map(\.start) == [1, 20, 3725])
        #expect(read.lines.map(\.text) == ["Hello.", "Hi there, everyone.", "Bye now."])
    }

    @Test("Notes with headings of their own read back whole")
    func notesWithHeadings() throws {
        var record = MeetingRecord(title: "Sync")
        record.notes = "## Before the call\n- one\n\n## Follow-ups\n- [ ] two"
        record.summary = "### Topic\n- point"
        record.add(line(.me, 1, "Hello."))
        let read = try #require(MeetingMarkdown.parse(MeetingMarkdown.render(record)))
        #expect(read.notes == record.notes)
        #expect(read.summary == record.summary)
        #expect(read.lines.count == 1)
    }

    @Test("A note written by hand, with no front matter, still reads as a meeting")
    func readsHandWritten() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let read = try #require(MeetingMarkdown.parse("# Standup\n\n## Notes\n\nall fine\n",
                                                      fallbackDate: date))
        #expect(read.title == "Standup")
        #expect(read.notes == "all fine")
        #expect(read.startDate == date)
        #expect(MeetingMarkdown.parse("just some text") == nil)
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

    @Test("Two meetings with one title in one minute get two files, and each keeps its own")
    func namesDoNotCollide() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var first = MeetingRecord(title: "Meeting", startDate: start)
        first.notes = "first"
        var second = MeetingRecord(title: "Meeting", startDate: start.addingTimeInterval(20))
        second.notes = "second"

        let firstURL = try MeetingMarkdown.write(first, to: folder)
        let secondURL = try MeetingMarkdown.write(second, to: folder)
        #expect(firstURL != secondURL)
        // Each rewrites its own file, not the other's.
        second.notes = "second, edited"
        #expect(try MeetingMarkdown.write(second, to: folder, replacing: secondURL) == secondURL)
        first.notes = "first, edited"
        #expect(try MeetingMarkdown.write(first, to: folder, replacing: firstURL) == firstURL)
        let notes = try [firstURL, secondURL].map {
            MeetingMarkdown.parse(try String(contentsOf: $0, encoding: .utf8))?.notes
        }
        #expect(notes == ["first, edited", "second, edited"])
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
    @Test("However long the notes and the transcript, the last prompt fits; the notes lead it")
    func finalPromptFits() {
        let notes = String(repeating: "a note that goes on ", count: 1_000)       // 20,000 characters
        let material = String(repeating: "something that was said ", count: 1_000)
        let prompt = MeetingSummarizer.finalPrompt(notes: notes, material: material, label: "Transcript")
        let heading = MeetingSummarizer.notesHeading
        #expect(prompt.count <= MeetingSummarizer.notesLimit + MeetingSummarizer.pieceLimit
                + heading.count + 100)
        #expect(prompt.hasPrefix(heading + "\na note"))
        #expect(prompt.contains("Transcript:\nsomething that was said"))

        // A model with room gets more of the notes — a fifth of what it
        // holds — and the transcript gives up exactly that much.
        let roomy = MeetingSummarizer.finalPrompt(notes: notes, material: material, label: "Transcript",
                                                  limit: 50_000)
        let keptNotes = roomy.components(separatedBy: "\n\nTranscript:\n")[0].count - heading.count - 1
        #expect(keptNotes == 10_001)                                  // 10,000 and the "…"
        #expect(roomy.count <= 50_000 + MeetingSummarizer.notesLimit + heading.count + 100)
        // Short notes cost the transcript nothing.
        let short = MeetingSummarizer.finalPrompt(notes: "a note", material: material, label: "T", limit: 9_000)
        #expect(short.hasSuffix(String(material.prefix(9_000))))
        #expect(MeetingSummarizer.finalPrompt(notes: "  ", material: "x", label: "T") == "T:\nx")
    }

    @Test("The last prompt opens with what the meeting was and who was invited")
    func promptNamesTheMeeting() {
        var record = MeetingRecord(title: "Kiln pricing")
        record.attendees = [MeetingAttendee(name: "Ana Ruiz"),
                            MeetingAttendee(markdown: "Tom Berg (declined)"),
                            MeetingAttendee(name: "Lee Chen")]
        let details = MeetingSummarizer.details(of: record)
        #expect(details.hasPrefix("Meeting: Kiln pricing\nDate: "))
        #expect(details.contains("Invited: Ana Ruiz, Lee Chen\n"))
        #expect(details.hasSuffix(MeetingSummarizer.attribution))

        let prompt = MeetingSummarizer.finalPrompt(about: details, notes: "n", material: "x", label: "T")
        #expect(prompt.hasPrefix(details + "\n\n" + MeetingSummarizer.notesHeading + "\nn\n\nT:\nx"))
    }

    @Test("A company-wide invitation does not crowd out the transcript")
    func attendeesAreCapped() {
        var record = MeetingRecord(title: "All hands")
        record.attendees = (0..<500).map { MeetingAttendee(name: "Person Number \($0)") }
        let details = MeetingSummarizer.details(of: record)
        #expect(details.count < MeetingSummarizer.attendeesLimit + 120
                + MeetingSummarizer.attribution.count)
        #expect(details.contains("Person Number 0,"))
        #expect(details.contains(" more"))
    }

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

    @Test("A call app that keeps the microphone is offered once; a browser only during a calendar call")
    func offers() {
        var watch = CallWatch()
        #expect(watch.offer(apps: [chrome], event: nil) == nil)
        #expect(watch.offer(apps: [chrome], event: call) == chrome)
        #expect(watch.offer(apps: [chrome], event: call) == nil)
        #expect(watch.offer(apps: [zoom], event: nil) == nil)      // first seen
        #expect(watch.offer(apps: [zoom], event: nil) == zoom)     // still there
        #expect(watch.offer(apps: [zoom], event: nil) == nil)
        // The call ends and another begins: offered again.
        #expect(watch.offer(apps: [], event: nil) == nil)
        #expect(watch.offer(apps: [zoom], event: nil) == nil)
        #expect(watch.offer(apps: [zoom], event: nil) == zoom)
    }

    @Test("A microphone opened for a moment is not a call, however often it happens")
    func ignoresAProbe() {
        var watch = CallWatch()
        for _ in 0..<5 {
            #expect(watch.offer(apps: [zoom], event: nil) == nil)
            #expect(watch.offer(apps: [], event: nil) == nil)
        }
        #expect(watch.offer(apps: [zoom], event: nil) == nil)
        #expect(watch.offer(apps: [zoom], event: nil) == zoom)
    }

    @Test("A calendar call is announced once as it starts; one declined, in a room alone, or all day is not")
    func announcesCalendarCalls() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, in seconds: TimeInterval, link: Bool = true, people: Int = 1,
                   declined: Bool = false, allDay: Bool = false) -> MeetingEvent {
            MeetingEvent(id: id, title: id, start: now.addingTimeInterval(seconds),
                         end: now.addingTimeInterval(seconds + 1_800), isAllDay: allDay,
                         attendees: (0..<people).map { MeetingAttendee(name: "P\($0)") },
                         joinURL: link ? URL(string: "https://example.com/\(id)") : nil,
                         declinedByMe: declined)
        }
        var watch = CallWatch()
        // Ten minutes off: not yet. Twenty seconds off: now. And only once.
        #expect(watch.starting(events: [event("later", in: 600)], now: now) == nil)
        let soon = event("standup", in: 20)
        #expect(watch.starting(events: [soon], now: now)?.id == "standup")
        #expect(watch.starting(events: [soon], now: now.addingTimeInterval(5)) == nil)
        // The Mac opened a minute into it: still worth saying. Ten minutes in: not.
        #expect(watch.starting(events: [event("late", in: -60)], now: now)?.id == "late")
        #expect(watch.starting(events: [event("missed", in: -600)], now: now) == nil)
        // Not calls, or not mine.
        #expect(watch.starting(events: [event("focus", in: 0, link: false, people: 1),
                                        event("declined", in: 0, declined: true),
                                        event("holiday", in: 0, allDay: true)], now: now) == nil)
        // People and no link is a meeting in a room: offered, to take notes.
        #expect(watch.starting(events: [event("room", in: 0, link: false, people: 3)], now: now)?.id == "room")

        // "Not Now" on the card: the call app opening its microphone for
        // that event is not asked about again; another event is.
        watch.decline(soon)
        #expect(watch.offer(apps: [zoom], event: soon) == nil)
        #expect(watch.offer(apps: [zoom], event: soon) == nil)
        #expect(watch.offer(apps: [zoom], event: call) == zoom)
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

// MARK: - A whole session, without hardware

/// Samples pushed by hand, as if a device delivered them.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var hasHeardSound = true
    private(set) var started = false
    private(set) var stopped = false
    func start() throws { started = true }
    func stop() { stopped = true }
    /// In blocks, the way a capture hands them over: each one arrives once
    /// the time it covers has passed.
    func push(_ samples: [Float], clock: TestClock) {
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 1024)
            clock.advance(Double(end - index) / AudioRecorder.sampleRate)
            onSamples?(Array(samples[index..<end]))
            index = end
        }
    }
}

/// Answers with words no other call shares, so one side's line is never
/// taken for the echo of the other's.
private actor LengthEngine: TranscriptionEngine {
    var isLoaded: Bool { true }
    func load(model: InstalledModel) async throws {}
    func unload() async {}
    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript {
        Transcript(text: "x" + UUID().uuidString.replacingOccurrences(of: "-", with: " x"))
    }
}

/// A clock the test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

@MainActor
@Suite("Meeting session")
struct MeetingSessionTests {
    private func session(mic: FakeSource, system: FakeSource, clock: TestClock,
                         folder: URL) -> MeetingSession {
        MeetingSession(
            title: "Test", folder: folder, queue: TranscriptionQueue(LengthEngine()),
            model: InstalledModel(id: "m", displayName: "M", sizeBytes: 0,
                                  url: URL(fileURLWithPath: "/nonexistent")),
            options: TranscribeOptions(), sensitivity: 0.5, micDeviceUID: nil,
            microphone: mic, systemAudio: system, now: { clock.now() })
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clio-session-\(UUID().uuidString)")
    }

    @Test("Silence from the call is looked into once: refused is said, a quiet call is left alone")
    func silenceIsProbed() async throws {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func ask() { lock.lock(); count += 1; lock.unlock() }
            var times: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        func meeting(answering result: SystemAudioProbe.Result,
                     asked: Asked, system: FakeSource, folder: URL) -> MeetingSession {
            let meeting = session(mic: FakeSource(), system: system, clock: TestClock(), folder: folder)
            meeting.silenceGrace = .milliseconds(10)
            meeting.silenceInterval = .milliseconds(10)
            meeting.probeSystemAudio = { asked.ask(); return result }
            return meeting
        }
        func wait(for status: MeetingSession.SystemAudioStatus, _ meeting: MeetingSession) async {
            for _ in 0..<200 where meeting.systemAudio != status {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Refused: said, asked once however long it lasts, and taken back
        // the moment something is heard.
        let system = FakeSource(), asked = Asked()
        system.hasHeardSound = false
        let refused = meeting(answering: .refused, asked: asked, system: system, folder: folder)
        await refused.start()
        await wait(for: .refused, refused)
        #expect(refused.systemAudio == .refused)
        try await Task.sleep(for: .milliseconds(80))
        #expect(asked.times == 1)
        system.hasHeardSound = true
        await wait(for: .listening, refused)
        #expect(refused.systemAudio == .listening)
        await refused.stop()

        // Allowed: nobody has spoken yet, and nothing is said about it.
        let quiet = FakeSource(), askedQuiet = Asked()
        quiet.hasHeardSound = false
        let allowed = meeting(answering: .allowed, asked: askedQuiet, system: quiet, folder: folder)
        await allowed.start()
        try await Task.sleep(for: .milliseconds(120))
        #expect(askedQuiet.times == 1)
        #expect(allowed.systemAudio == .listening)
        await allowed.stop()

        // The probe could not run: the old, careful wording.
        let unknown = FakeSource()
        unknown.hasHeardSound = false
        let inconclusive = meeting(answering: .inconclusive("no output"), asked: Asked(),
                                   system: unknown, folder: folder)
        await inconclusive.start()
        await wait(for: .silent, inconclusive)
        #expect(inconclusive.systemAudio == .silent)
        await inconclusive.stop()
    }

    @Test("Both sides are transcribed, in time order, and stop waits for the last of them before the file is final")
    func drainsOnStop() async throws {
        let mic = FakeSource(), system = FakeSource(), clock = TestClock(), folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
        await meeting.start()
        #expect(meeting.phase == .recording)
        #expect(mic.started && system.started)

        system.push(silence(1) + tone(2) + silence(2), clock: clock)
        mic.push(silence(1) + tone(2), clock: clock)     // still talking when stop is pressed
        await meeting.stop()

        #expect(meeting.phase == .finished)
        #expect(mic.stopped && system.stopped)
        #expect(meeting.record.lines.map(\.speaker) == [.others, .me])
        #expect(meeting.pendingChunks == 0)
        let file = try String(contentsOf: try #require(meeting.fileURL), encoding: .utf8)
        #expect(file.contains("Others:**"))
        #expect(file.contains("Me:**"))
        #expect(!file.contains("in progress"))
    }

    @Test("Time with no samples at all still counts: a line after a long quiet stretch is stamped when it was said")
    func wallClockGaps() async throws {
        let mic = FakeSource(), system = FakeSource(), clock = TestClock(), folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
        await meeting.start()

        system.push(silence(1) + tone(2), clock: clock)   // said at about 1 s
        clock.advance(120)                                // the tap sends nothing for two minutes
        system.push(tone(2) + silence(2), clock: clock)   // said at about 123 s
        await meeting.stop()

        let starts = meeting.record.lines.map(\.start)
        #expect(starts.count == 2)
        #expect(abs(starts[0] - 1) < 0.5)
        #expect(abs(starts[1] - 123) < 0.5)
    }

    @Test("While dictating, the meeting does not hear the microphone")
    func suppressedWhileDictating() async throws {
        let mic = FakeSource(), system = FakeSource(), clock = TestClock(), folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
        await meeting.start()

        meeting.isMicrophoneSuppressed = true
        mic.push(tone(3) + silence(1), clock: clock)
        meeting.isMicrophoneSuppressed = false
        await meeting.stop()

        #expect(meeting.record.lines.isEmpty)
    }

    @Test("Stop pressed while the microphone is still opening leaves nothing running")
    func stopDuringStart() async throws {
        /// Takes a while to start, like real hardware, and says whether it
        /// was left running.
        final class SlowSource: MeetingAudioSource, @unchecked Sendable {
            var onSamples: (@Sendable ([Float]) -> Void)?
            var hasHeardSound = true
            private let lock = NSLock()
            private var running = false
            var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
            func start() throws {
                Thread.sleep(forTimeInterval: 0.3)
                lock.lock(); running = true; lock.unlock()
            }
            func stop() { lock.lock(); running = false; lock.unlock() }
        }
        let mic = SlowSource(), system = SlowSource(), clock = TestClock(), folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = MeetingSession(
            title: "Test", folder: folder, queue: TranscriptionQueue(LengthEngine()),
            model: InstalledModel(id: "m", displayName: "M", sizeBytes: 0,
                                  url: URL(fileURLWithPath: "/nonexistent")),
            options: TranscribeOptions(), sensitivity: 0.5, micDeviceUID: nil,
            microphone: mic, systemAudio: system, now: { clock.now() })

        let starting = Task { await meeting.start() }
        try await Task.sleep(for: .milliseconds(100))   // the mic is still opening
        await meeting.stop()
        await starting.value

        #expect(meeting.phase == .finished)
        #expect(!mic.isRunning)
        #expect(!system.isRunning)
    }

    @Test("Chunks that keep failing to transcribe are said out loud, not dropped in silence")
    func transcriptionFailuresAreReported() async throws {
        actor BrokenEngine: TranscriptionEngine {
            struct Gone: LocalizedError { var errorDescription: String? { "The model is missing." } }
            var isLoaded: Bool { false }
            func load(model: InstalledModel) async throws { throw Gone() }
            func unload() async {}
            func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript {
                throw Gone()
            }
        }
        let mic = FakeSource(), system = FakeSource(), clock = TestClock(), folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = MeetingSession(
            title: "Test", folder: folder, queue: TranscriptionQueue(BrokenEngine()),
            model: InstalledModel(id: "m", displayName: "M", sizeBytes: 0,
                                  url: URL(fileURLWithPath: "/nonexistent")),
            options: TranscribeOptions(), sensitivity: 0.5, micDeviceUID: nil,
            microphone: mic, systemAudio: system, now: { clock.now() })
        await meeting.start()
        system.push(tone(2) + silence(2) + tone(2) + silence(2), clock: clock)
        await meeting.stop(summarizing: false)
        #expect(meeting.transcriptionProblem?.contains("The model is missing.") == true)
    }

    @Test("The summary is written after the transcript, and skipped when asked")
    func summary() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for summarizing in [true, false] {
            let mic = FakeSource(), system = FakeSource(), clock = TestClock()
            let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
            meeting.summarize = { record in "### Lines\n- \(record.lines.count)" }
            await meeting.start()
            system.push(tone(2) + silence(1), clock: clock)
            await meeting.stop(summarizing: summarizing)
            #expect(meeting.record.summary == (summarizing ? "### Lines\n- 1" : nil))
        }
    }

    @Test("With a diarizer, the call is recorded on the meeting's clock, its lines put on voices and named, and the recording deleted")
    func voices() async throws {
        final class FakeDiarizer: SpeakerDiarizing, @unchecked Sendable {
            var seconds = 0.0
            var soundAt: Double?
            var file: URL?
            var fails = false
            func diarize(recording file: URL) async throws -> Diarization {
                struct Broken: Error {}
                if fails { throw Broken() }
                self.file = file
                let samples = try StreamRecording.samples(at: file)
                seconds = Double(samples.count) / AudioRecorder.sampleRate
                soundAt = samples.firstIndex { $0 != 0 }.map { Double($0) / AudioRecorder.sampleRate }
                // Whoever spoke first, then someone else from 20 s on.
                return Diarization(spans: [SpeakerSpan(speaker: 5, start: 0, end: 20),
                                           SpeakerSpan(speaker: 2, start: 20, end: 60)],
                                   voiceprints: [5: [1, 0], 2: [0, 1]], space: "test")
            }
        }
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let mic = FakeSource(), system = FakeSource(), clock = TestClock(), diarizer = FakeDiarizer()
        let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
        meeting.diarizer = diarizer
        meeting.nameVoices = { record, voices in
            #expect(record.voiceNumbers == [1, 2])
            // The voiceprints come under the transcript's numbers, not the
            // diarizer's, each with how long its voice spoke.
            #expect(voices.space == "test")
            #expect(voices.samples[1] == VoiceSample(vector: [1, 0], seconds: 20))
            #expect(voices.samples[2] == VoiceSample(vector: [0, 1], seconds: 40))
            return [2: "Ana Ruiz"]
        }
        final class Kept: @unchecked Sendable { var names: [Int: MeetingVoice] = [:] }
        let kept = Kept()
        meeting.voicesIdentified = { record, _ in kept.names = record.voices }
        meeting.summarize = { record in record.transcriptText }
        await meeting.start()
        clock.advance(10)                                        // nobody speaks for ten seconds
        system.push(tone(3) + silence(3), clock: clock)
        clock.advance(10)                                        // and the tap sends nothing for ten more
        system.push(tone(3) + silence(1), clock: clock)
        mic.push(tone(2) + silence(1), clock: clock)
        await meeting.stop()

        // The file had the meeting's time in it: the waits as silence.
        #expect(abs(diarizer.seconds - 30) < 1.5)
        #expect(abs((diarizer.soundAt ?? 0) - 10) < 0.5)
        let lines = meeting.record.lines
        #expect(lines.map(\.voice) == [1, 2, nil])
        #expect(lines.map(meeting.record.label(for:)) == ["Speaker 1", "Ana Ruiz", "Me"])
        #expect(meeting.record.voices[2] == MeetingVoice(name: "Ana Ruiz", confirmed: false))
        // What is kept for later meetings is kept after the names are in.
        #expect(kept.names == [2: MeetingVoice(name: "Ana Ruiz", confirmed: false)])
        // The summary is written after, from a transcript that has the names.
        #expect(meeting.record.summary?.contains("Ana Ruiz:") == true)
        // And the audio is gone.
        let file = try #require(diarizer.file)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Named by hand afterwards: the user's, in the file.
        meeting.nameVoice(1, as: "Tom")
        let saved = try String(contentsOf: try #require(meeting.fileURL), encoding: .utf8)
        #expect(saved.contains("speaker-1: Tom\n") && saved.contains("speaker-2-guess: Ana Ruiz\n"))

        // A diarizer that fails leaves a meeting of Me and Others, and no file.
        let broken = FakeDiarizer()
        broken.fails = true
        let second = session(mic: FakeSource(), system: system, clock: clock, folder: folder)
        second.diarizer = broken
        await second.start()
        let recordings = second.recordingURLs
        #expect(recordings.count == 1)                           // the call's side only
        system.push(tone(3) + silence(3), clock: clock)
        await second.stop()
        #expect(second.phase == .finished)
        #expect(second.record.lines.map(second.record.label(for:)) == ["Others"])
        #expect(recordings.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("With audio kept, both sides are beside the notes on the meeting's clock, follow a rename, and nothing else is left")
    func keepsAudio() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = FakeSource(), system = FakeSource(), clock = TestClock()
        let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
        meeting.keepsAudio = true
        await meeting.start()
        let recordings = meeting.recordingURLs
        #expect(recordings.count == 2)
        clock.advance(5)
        system.push(tone(3) + silence(2), clock: clock)
        mic.push(tone(2) + silence(1), clock: clock)
        await meeting.stop()

        let file = try #require(meeting.fileURL)
        let audio = MeetingAudio.files(for: file)
        #expect(Set(audio.keys) == [.me, .others])
        #expect(audio[.others]?.lastPathComponent == file.deletingPathExtension().lastPathComponent + ".others.m4a")
        // Each as long as the meeting had run when its side last spoke:
        // 5 s of waiting and 5 of the call; then 3 more of the microphone.
        func seconds(_ url: URL) throws -> Double {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.fileFormat.sampleRate
        }
        #expect(abs(try seconds(try #require(audio[.others])) - 10) < 0.6)
        #expect(abs(try seconds(try #require(audio[.me])) - 13) < 0.6)
        // The recordings they were made from are gone.
        #expect(recordings.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        // Renamed: the audio takes the new name; trashed: it goes too.
        meeting.setTitle("Renamed")
        let renamed = try #require(meeting.fileURL)
        #expect(renamed != file)
        #expect(MeetingAudio.files(for: file).isEmpty)
        #expect(MeetingAudio.files(for: renamed).count == 2)
        let library = MeetingLibrary(folder: folder)
        try library.trash(renamed)
        #expect(MeetingAudio.files(for: renamed).isEmpty)

        // And without the setting, there is never any.
        let plain = session(mic: FakeSource(), system: system, clock: clock, folder: folder)
        await plain.start()
        system.push(tone(3) + silence(2), clock: clock)
        await plain.stop()
        #expect(MeetingAudio.files(for: try #require(plain.fileURL)).isEmpty)
    }

    @Test("Kept audio past its days is deleted; newer audio, and files that are not Clio's, are not")
    func audioExpires() throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func make(_ name: String, daysAgo: Double) throws {
            let url = folder.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
        try make("Old.me.m4a", daysAgo: 40)
        try make("Old.others.m4a", daysAgo: 40)
        try make("Old.md", daysAgo: 40)
        try make("New.others.m4a", daysAgo: 3)
        try make("My own song.m4a", daysAgo: 400)
        #expect(MeetingAudio.removeExpired(in: folder, olderThan: 30, now: now) == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["My own song.m4a", "New.others.m4a", "Old.md"])
        #expect(MeetingAudioRetention.month.days == 30)
        #expect(MeetingAudioRetention.off.days == nil && MeetingAudioRetention.forever.days == nil)
    }

    @Test("A recording made elsewhere becomes a meeting: dated as the file, every line someone on it, saved and finished")
    func importsARecording() async throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Board call.wav")
        try AudioWAV.data(silence(2) + tone(3) + silence(3) + tone(4) + silence(2)).write(to: file)
        let made = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: file.path)

        final class Progress: @unchecked Sendable { var values: [Double] = [] }
        let progress = Progress()
        let meeting = try await MeetingImport.run(
            file: file, folder: folder, queue: TranscriptionQueue(LengthEngine()),
            model: InstalledModel(id: "m", displayName: "M", sizeBytes: 0, url: URL(fileURLWithPath: "/nonexistent")),
            options: TranscribeOptions(), sensitivity: 0.5,
            configure: { session in
                session.keepsAudio = true                       // not for an import: the file is the audio
                session.summarize = { record in "### Lines\n- \(record.lines.count)" }
            },
            progress: { progress.values.append($0) })

        #expect(meeting.phase == .finished)
        #expect(meeting.record.title == "Board call")
        #expect(abs(meeting.record.startDate.timeIntervalSince(made)) < 1)
        #expect(meeting.record.lines.count == 2)
        #expect(meeting.record.lines.allSatisfy { $0.speaker == .others })
        // Stamped where they are in the file.
        #expect(abs(meeting.record.lines[0].start - 2) < 1 && abs(meeting.record.lines[1].start - 8) < 1)
        #expect(meeting.record.summary == "### Lines\n- 2")
        #expect(progress.values.last == 1)
        let saved = try #require(meeting.fileURL)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(MeetingAudio.files(for: saved).isEmpty)

        // Not a recording at all, and one with nothing in it.
        let text = folder.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: text)
        await #expect(throws: MeetingImport.ImportError.self) {
            _ = try await MeetingImport.run(
                file: text, folder: folder, queue: TranscriptionQueue(LengthEngine()),
                model: InstalledModel(id: "m", displayName: "M", sizeBytes: 0, url: URL(fileURLWithPath: "/nonexistent")),
                options: TranscribeOptions(), sensitivity: 0.5, configure: { _ in }, progress: { _ in })
        }
    }

    @Test("Notes written by hand for an event are carried on by a recording: one file, the notes kept, the transcript added")
    func recordsIntoNotes() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let event = MeetingEvent(id: "e1", title: "Pricing call", start: start,
                                 end: start.addingTimeInterval(1_800),
                                 attendees: [MeetingAttendee(name: "Ana Ruiz")],
                                 joinURL: URL(string: "https://example.com/call"))
        // Written by hand first: nothing recorded.
        var notes = MeetingRecord.notes(for: event)
        #expect(notes.title == "Pricing call" && notes.eventID == "e1" && notes.lines.isEmpty)
        #expect(notes.startDate == start && notes.endDate == event.end)
        notes.notes = "- ask about the starter tier"
        let written = try MeetingMarkdown.write(notes, to: folder)

        // Then recorded, from the notes' page.
        let mic = FakeSource(), system = FakeSource(), clock = TestClock()
        let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
        meeting.titleIsPlaceholder = true
        meeting.adopt(try #require(MeetingMarkdown.parse(try String(contentsOf: written, encoding: .utf8))),
                      at: written)
        await meeting.start()
        system.push(tone(2) + silence(2), clock: clock)
        await meeting.stop()

        let record = meeting.record
        #expect(record.title == "Pricing call" && !meeting.titleIsPlaceholder)
        #expect(record.notes == "- ask about the starter tier")
        #expect(record.eventID == "e1" && record.attendees.map(\.name) == ["Ana Ruiz"])
        #expect(record.joinURL == event.joinURL)
        #expect(record.lines.count == 1)
        // One file: the notes' own, renamed for when the recording began.
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1)
        #expect(!FileManager.default.fileExists(atPath: written.path))
        let saved = try String(contentsOf: try #require(meeting.fileURL), encoding: .utf8)
        #expect(saved.contains("- ask about the starter tier") && saved.contains("event: e1"))
    }

    @Test("A meeting Clio named is renamed from its summary, and its file with it; one the user or the calendar named is not")
    func titleFromTheSummary() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(placeholder: Bool, typed: String? = nil) async -> MeetingSession {
            let mic = FakeSource(), system = FakeSource(), clock = TestClock()
            let meeting = session(mic: mic, system: system, clock: clock, folder: folder)
            meeting.titleIsPlaceholder = placeholder
            meeting.summarize = { _ in "### Pricing\n- Agreed." }
            meeting.suggestTitle = { summary in summary.contains("Pricing") ? "Pricing review" : nil }
            await meeting.start()
            if let typed { meeting.setTitle(typed) }
            system.push(tone(2) + silence(1), clock: clock)
            await meeting.stop()
            return meeting
        }
        let named = await run(placeholder: true)
        #expect(named.record.title == "Pricing review")
        #expect(named.fileURL?.lastPathComponent.contains("Pricing review") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)

        #expect(await run(placeholder: false).record.title == "Test")
        #expect(await run(placeholder: true, typed: "Mine").record.title == "Mine")
    }
}

// MARK: - The library

@MainActor
@Suite("Meeting library")
struct MeetingLibraryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ title: String, daysAgo: Double, notes: String = "",
                       said: String = "Hello there.", to folder: URL) throws -> URL {
        var record = MeetingRecord(title: title,
                                   startDate: Date().addingTimeInterval(-daysAgo * 86_400))
        record.notes = notes
        record.add(MeetingLine(speaker: .others, start: 1, end: 3, text: said))
        return try MeetingMarkdown.write(record, to: folder)
    }

    @Test("The folder is read newest first; files that are not meetings are left out")
    func scans() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write("Old", daysAgo: 40, to: folder)
        _ = try write("New", daysAgo: 0, to: folder)
        try Data("not a meeting".utf8).write(to: folder.appendingPathComponent("readme.md"))
        try Data("# Not markdown".utf8).write(to: folder.appendingPathComponent("x.txt"))
        #expect(MeetingLibrary.scan(folder).map(\.title) == ["New", "Old"])
    }

    @Test("A rescan reads only the files that changed")
    func rescansOnlyChanges() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = try write("Kept", daysAgo: 1, to: folder)
        let edited = try write("Edited", daysAgo: 2, to: folder)
        // Whole seconds: a date with a fraction can come back from the file
        // system rounded, which reads as a change.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: kept.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: edited.path)
        let (_, cache) = MeetingLibrary.scan(folder, cache: [:])

        // A change the cache cannot see — same modification date — proves
        // the file was not read again; a real edit is.
        try Data(try String(contentsOf: kept, encoding: .utf8)
            .replacingOccurrences(of: "# Kept", with: "# Changed unseen").utf8).write(to: kept)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: kept.path)
        try Data(try String(contentsOf: edited, encoding: .utf8)
            .replacingOccurrences(of: "# Edited", with: "# Edited again").utf8).write(to: edited)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)],
                                              ofItemAtPath: edited.path)

        let titles = Set(MeetingLibrary.scan(folder, cache: cache).files.map(\.title))
        #expect(titles == ["Kept", "Edited again"])
    }

    @Test("Search finds every word, in the title, the notes or what was said")
    func searches() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write("Pricing call", daysAgo: 1, notes: "raise the starter tier", to: folder)
        _ = try write("Design review", daysAgo: 2, said: "The icon needs more contrast.", to: folder)
        let library = MeetingLibrary(folder: folder)
        while !library.hasLoaded { try await Task.sleep(for: .milliseconds(10)) }
        #expect(library.search("pricing").map(\.title) == ["Pricing call"])
        #expect(library.search("starter tier").map(\.title) == ["Pricing call"])
        #expect(library.search("icon contrast").map(\.title) == ["Design review"])
        #expect(library.search("icon pricing").isEmpty)
        #expect(library.search("").count == 2)
    }

    @Test("Edits are written back, a new title moves the file, and the Trash takes it")
    func editsAndTrashes() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try write("Sync", daysAgo: 0, to: folder)
        let library = MeetingLibrary(folder: folder)
        var record = try #require(library.record(at: url))
        record.title = "Weekly sync"
        record.notes = "decided: ship"
        let moved = try library.save(record, at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(library.record(at: moved)?.notes == "decided: ship")
        #expect(library.record(at: moved)?.lines.count == 1)

        try library.trash(moved)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    @Test("Grouped into Today, Yesterday, then months")
    func groups() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func file(_ daysAgo: Double) -> MeetingFile {
            MeetingFile(url: URL(fileURLWithPath: "/\(daysAgo).md"), title: "\(daysAgo)",
                        start: now.addingTimeInterval(-daysAgo * 86_400), end: nil,
                        attendees: [], eventID: nil, preview: "", searchText: "")
        }
        let groups = MeetingLibrary.groups([file(40), file(0), file(1), file(0.01), file(60)],
                                           now: now)
        #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(groups.first?.files.count == 2)
        #expect(groups.count == 4)
    }
}

@MainActor
@Test("One dictation can be removed from the history, and the rest stay in order")
func removeDictation() {
    let store = HistoryStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-history-\(UUID().uuidString).json"))
    store.add("first")
    store.add("second")
    store.add("third")
    let middle = store.entries[1].id
    store.remove(id: middle)
    #expect(store.entries.map(\.text) == ["third", "first"])
}

// MARK: - A day in the calendar

@Suite("Day agenda")
struct DayAgendaTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()
    /// 3 Nov 2026, 00:00 in Warsaw.
    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))!
    }

    private func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }

    private func event(_ id: String, _ title: String, from: Double, to: Double,
                       allDay: Bool = false, declined: Bool = false,
                       key: String? = nil) -> MeetingEvent {
        MeetingEvent(id: id, externalID: key, title: title, start: at(from), end: at(to),
                     isAllDay: allDay, declinedByMe: declined)
    }

    private func file(_ title: String, at hour: Double, event: String? = nil,
                      key: String? = nil) -> MeetingFile {
        MeetingFile(url: URL(fileURLWithPath: "/\(title)-\(hour).md"), title: title,
                    start: at(hour), end: nil, attendees: [], eventID: event, eventKey: key,
                    preview: "", searchText: "")
    }

    @Test("Notes whose event has a new id since are still its: by the server's name, then by title")
    func survivesANewID() {
        let events = [event("new-1", "Weekly Demos", from: 17, to: 17.5, key: "server-1"),
                      event("new-2", "Design Hangout", from: 16, to: 17)]
        let files = [file("Renamed since", at: 17.05, event: "old-1", key: "server-1"),
                     // No key, as every file before there was one; and begun
                     // long before the hour.
                     file("Design Hangout", at: 8.6, event: "old-2")]
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: [],
                                    calendar: calendar)
        #expect(agenda.events.map(\.notes?.title) == ["Design Hangout", "Renamed since"])
        #expect(agenda.otherNotes.isEmpty)
    }

    @Test("Notes with a stale id and another name are matched by time, as notes with none are")
    func staleIDByTime() {
        let events = [event("new", "Sync", from: 10, to: 11)]
        let files = [file("My own title", at: 10.2, event: "old")]
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: [],
                                    calendar: calendar)
        #expect(agenda.events.first?.notes?.title == "My own title")
    }

    @Test("Two events with one name each take the notes begun nearest them")
    func sameNameTwice() {
        let events = [event("am", "Standup", from: 9, to: 9.5), event("pm", "Standup", from: 15, to: 15.5)]
        let files = [file("Standup", at: 15.1), file("Standup", at: 8.7)]
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: [],
                                    calendar: calendar)
        #expect(agenda.events.map(\.notes?.start) == [at(8.7), at(15.1)])
    }

    @Test("Notes given to an event are its, whatever they are called and whenever they began")
    func givenToAnEvent() {
        let events = [event("e1", "Planning", from: 10, to: 11, key: "k1")]
        var record = MeetingRecord(title: "Thoughts", startDate: at(19))
        record.link(to: events[0])
        let read = try! #require(MeetingMarkdown.parse(MeetingMarkdown.render(record)))
        #expect(read.eventID == "e1" && read.eventKey == "k1")
        // Its own notes, by title and time, lose to the ones it was given.
        let files = [file("Planning", at: 10.1),
                     file("Thoughts", at: 19, event: read.eventID, key: read.eventKey)]
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: [],
                                    calendar: calendar)
        #expect(agenda.events.first?.notes?.title == "Thoughts")
        #expect(agenda.otherNotes.map(\.title) == ["Planning"])
        record.unlink()
        #expect(!MeetingMarkdown.render(record).contains("event"))
    }

    @Test("Notes that name their event are its; the rest are matched by time, the same title first")
    func linksNotes() {
        let events = [event("e1", "Standup", from: 9.5, to: 10),
                      event("e2", "1:1 with Ana", from: 11, to: 11.5),
                      event("e3", "Design review", from: 14, to: 15)]
        let files = [file("Renamed later", at: 9.45, event: "e1"),   // says so
                     file("Meeting at 10:58", at: 10.97),             // early, by time
                     file("Design review", at: 14.1),                  // same title wins…
                     file("Scratch", at: 14.05)]                       // …over an earlier one
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: [],
                                    calendar: calendar)
        #expect(agenda.events.map(\.notes?.title) == ["Renamed later", "Meeting at 10:58", "Design review"])
        #expect(agenda.otherNotes.map(\.title) == ["Scratch"])
    }

    @Test("Only the day's own: all-day and declined events are left out, other days' notes too")
    func onlyTheDay() {
        let events = [event("all", "Holiday", from: 0, to: 24, allDay: true),
                      event("no", "Declined", from: 12, to: 13, declined: true),
                      event("ok", "Lunch", from: 12, to: 13)]
        let files = [file("Yesterday's", at: -5), file("Today's", at: 16)]
        let dictations = [TranscriptEntry(text: "today", date: at(8)),
                          TranscriptEntry(text: "tomorrow", date: at(30))]
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: dictations,
                                    calendar: calendar)
        #expect(agenda.events.map(\.event.id) == ["ok"])
        #expect(agenda.otherNotes.map(\.title) == ["Today's"])
        #expect(agenda.dictations.map(\.text) == ["today"])
    }

    @Test("One set of notes per event, and one event per set of notes")
    func oneToOne() {
        let events = [event("a", "Sync", from: 10, to: 11), event("b", "Sync", from: 10, to: 11)]
        let files = [file("Sync", at: 10.1)]
        let agenda = DayAgenda.make(day: day, events: events, files: files, dictations: [],
                                    calendar: calendar)
        #expect(agenda.events.compactMap(\.notes).count == 1)
        #expect(agenda.otherNotes.isEmpty)
    }

    @Test("‹ and › step a day at a time, from midnight")
    func steps() {
        let next = DayAgenda.step(at(15), by: 1, calendar: calendar)
        #expect(next == day.addingTimeInterval(86_400))
        #expect(DayAgenda.step(at(15), by: -1, calendar: calendar) == day.addingTimeInterval(-86_400))
    }

    @Test("The event a meeting was taken for is kept in its file")
    func eventInFrontMatter() throws {
        var record = MeetingRecord(title: "Standup")
        record.eventID = "ABC-123:2026"
        let read = try #require(MeetingMarkdown.parse(MeetingMarkdown.render(record)))
        #expect(read.eventID == "ABC-123:2026")
    }
}

@Suite("Calendar colour")
struct CalendarColorTests {
    @Test("A calendar's colour comes through as sRGB, whatever space it was in")
    func converts() {
        let blue = CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        #expect(CalendarColor(blue) == CalendarColor(red: 0.2, green: 0.5, blue: 0.9))
        // Generic grey is gamma-encoded on the way to sRGB: still grey.
        let grey = CalendarColor(CGColor(gray: 0.5, alpha: 1))
        #expect(grey != nil)
        #expect(grey?.red == grey?.green && grey?.green == grey?.blue)
        #expect(CalendarColor(nil) == nil)
    }
}

@Suite("Summary page")
struct SummaryPageTests {
    @Test("The summary is shown and copied under the meeting's name as a heading")
    func titled() {
        var record = MeetingRecord(title: "Weekly sync")
        #expect(record.titledSummary == nil)
        record.summary = "  \n"
        #expect(record.titledSummary == nil)
        record.summary = "### Beta\n- Thursday\n"
        #expect(record.titledSummary == "# Weekly sync\n\n### Beta\n- Thursday")
        record.title = "Renamed"
        #expect(record.titledSummary?.hasPrefix("# Renamed\n") == true)
    }
}
