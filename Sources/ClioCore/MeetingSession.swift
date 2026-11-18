import Foundation
import Observation

/// Where one side of a meeting comes from: the microphone, the system audio,
/// or — in tests — samples pushed by hand.
public protocol MeetingAudioSource: AnyObject, Sendable {
    /// Called on the source's own thread with 16 kHz mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    func start() throws
    func stop()
    /// Whether anything but silence has arrived.
    var hasHeardSound: Bool { get }
    /// Whether it is capturing now. A source can stop on its own — the call
    /// audio, when the output changed and could not be picked up again.
    var isCapturing: Bool { get }
}

extension MeetingAudioSource {
    public var isCapturing: Bool { true }
}

extension SystemAudioRecorder: MeetingAudioSource {}

/// The voices of a meeting as the diarizer left them, by the numbers the
/// transcript uses.
public struct IdentifiedVoices: Sendable, Equatable {
    public var samples: [Int: VoiceSample]
    public var space: String

    public init(samples: [Int: VoiceSample], space: String) {
        self.samples = samples
        self.space = space
    }
}

/// The microphone, streaming: an `AudioRecorder` that keeps nothing.
public final class MeetingMicrophone: MeetingAudioSource, @unchecked Sendable {
    public let recorder = AudioRecorder()
    private let deviceUID: String?

    public init(deviceUID: String?) { self.deviceUID = deviceUID }

    public var onSamples: (@Sendable ([Float]) -> Void)? {
        get { recorder.onSamples }
        set { recorder.onSamples = newValue }
    }
    public func start() throws { try recorder.start(maxSeconds: 0, deviceUID: deviceUID) }
    public func stop() { recorder.stop() }
    public var hasHeardSound: Bool { recorder.buffersReceived > 0 }
}

/// One meeting being recorded: both sides of the call, cut at the pauses,
/// transcribed as it goes, and kept on disk as Markdown the whole time.
///
/// The microphone is "Me" and the system audio is "Others" — two streams,
/// so who said what needs no speaker analysis. Each stream has a
/// `SpeechSegmenter`; each chunk it cuts is transcribed through the shared
/// `TranscriptionQueue` behind any dictation, and lands in the record at the
/// time it was said. The file is rewritten after every line, so a crash
/// costs the chunk in flight and nothing before it.
@MainActor
@Observable
public final class MeetingSession {

    public enum Phase: Equatable, Sendable {
        case starting
        case recording
        /// Stopped; the last chunks are still being transcribed.
        case finishing
        /// Telling the voices on the call apart, and working out whose
        /// they are.
        case identifying
        /// Writing the summary.
        case summarizing
        case finished
        case failed(String)
    }

    /// What is coming from the other side of the call.
    public enum SystemAudioStatus: Equatable, Sendable {
        case starting
        case listening
        /// Running, but nothing but silence so far, and the probe could
        /// not say why.
        case silent
        /// Running, and not allowed to hear: the probe's own tone came back
        /// as silence.
        case refused
        case unavailable(String)
    }

    public private(set) var phase: Phase = .starting
    public private(set) var systemAudio: SystemAudioStatus = .starting
    public private(set) var microphoneProblem: String?
    public private(set) var record: MeetingRecord
    /// Where the Markdown is. Nil until the first write.
    public private(set) var fileURL: URL?
    public private(set) var saveProblem: String?
    /// Set once chunks keep failing to transcribe — the model gone or
    /// broken — so a meeting cannot end empty without a word. Cleared by the
    /// next chunk that works.
    public private(set) var transcriptionProblem: String?
    private var failedInARow = 0
    /// Chunks cut but not yet transcribed: how far behind the transcript is.
    public private(set) var pendingChunks = 0
    /// The microphone's level and the meter's five bands, for the recorder
    /// pill on the meeting's page. Zero and empty while nothing is heard.
    public private(set) var micLevel: Float = 0
    public private(set) var micBands: [Float] = []
    public let startedAt: Date

    /// Set while a dictation is recording, so the words meant for a text
    /// field do not also turn up in the meeting as "Me".
    public var isMicrophoneSuppressed: Bool {
        get { micFeed.isSuppressed }
        set { micFeed.isSuppressed = newValue }
    }

    /// The model to transcribe the next chunk with — the one dictation uses
    /// now. Nil keeps the one the meeting started with. Without it a model
    /// changed in Settings mid-meeting was loaded for every dictation and
    /// unloaded for every chunk, seconds each way.
    public var currentModel: (() -> InstalledModel?)?

    /// Tells the others' voices apart when the meeting ends. Set before
    /// `start`: with one, the call's side is written to a temporary file
    /// as it arrives — and deleted the moment the voices are told apart,
    /// or the meeting ends any other way. Nil, and nothing is written.
    public var diarizer: (any SpeakerDiarizing)?
    /// Works out whose the voices are, once they are apart — from the
    /// voices themselves, and from what was said. What it returns are
    /// guesses, by voice.
    public var nameVoices: ((MeetingRecord, IdentifiedVoices) async -> [Int: String])?
    /// Run once the voices have what names they are going to get: where
    /// they are kept for the meetings to come.
    public var voicesIdentified: ((MeetingRecord, IdentifiedVoices) async -> Void)?
    private var recording: StreamRecording?
    /// Keep both sides of the meeting as audio beside its notes. Set
    /// before `start`. Off, nothing of the microphone is written at all,
    /// and the call's side only for as long as telling its voices apart
    /// takes.
    public var keepsAudio = false
    private var micRecording: StreamRecording?
    /// Where the meeting's audio is being written while it runs, for the
    /// tests to see that it is gone afterwards.
    var recordingURLs: [URL] { [recording?.url, micRecording?.url].compactMap { $0 } }

    /// Run after the last chunk is in, to write the summary. Nil skips it.
    public var summarize: ((MeetingRecord) async -> String?)?
    /// Names the meeting from its summary. Asked only while
    /// `titleIsPlaceholder`.
    public var suggestTitle: ((String) async -> String?)?
    /// Whether the title is one Clio made up ("Meeting at 14:30") rather
    /// than the calendar's or the user's. Only such a title is replaced.
    public var titleIsPlaceholder = false

    private let folder: URL
    private let queue: TranscriptionQueue
    private let model: InstalledModel
    private let options: TranscribeOptions
    private let microphone: MeetingAudioSource
    private let systemRecorder: MeetingAudioSource
    private let now: @Sendable () -> Date
    private let micFeed: StreamFeed
    private let systemFeed: StreamFeed
    private var transcriptions: [UUID: Task<Void, Never>] = [:]
    private var silenceCheck: Task<Void, Never>?
    /// Asked once, when twenty seconds have gone by in silence: is that the
    /// call being quiet, or the permission? Nil where there is no real tap.
    var probeSystemAudio: (@Sendable () async -> SystemAudioProbe.Result)?
    /// How long silence lasts before it is looked into, and how often after.
    var silenceGrace: Duration = .seconds(20)
    var silenceInterval: Duration = .seconds(5)

    public init(title: String,
                folder: URL,
                queue: TranscriptionQueue,
                model: InstalledModel,
                options: TranscribeOptions,
                sensitivity: Double,
                micDeviceUID: String?,
                microphone: MeetingAudioSource? = nil,
                systemAudio: MeetingAudioSource? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let start = now()
        startedAt = start
        self.now = now
        record = MeetingRecord(title: title, startDate: start)
        self.folder = folder
        self.queue = queue
        self.model = model
        self.options = options
        self.microphone = microphone ?? MeetingMicrophone(deviceUID: micDeviceUID)
        self.systemRecorder = systemAudio ?? SystemAudioRecorder()
        // Only for the real tap: a stand-in has no permission to ask about.
        if systemAudio == nil {
            probeSystemAudio = { await SystemAudioProbe.run() }
        }
        let configuration = SpeechSegmenter.Configuration(sensitivity: sensitivity)
        micFeed = StreamFeed(speaker: .me, meetingStart: start, configuration: configuration, now: now)
        systemFeed = StreamFeed(speaker: .others, meetingStart: start, configuration: configuration, now: now)
    }

    #if DEBUG
    /// A meeting that never touched a microphone, in whatever state the
    /// window needs showing in — for the CLIO_MEETING_SHOW tool.
    public static func simulated(record: MeetingRecord, phase: Phase,
                                 systemAudio: SystemAudioStatus = .listening,
                                 pendingChunks: Int = 0) -> MeetingSession {
        let session = MeetingSession(
            title: record.title,
            folder: FileManager.default.temporaryDirectory
                .appendingPathComponent("clio-meeting-preview"),
            queue: TranscriptionQueue(StubTranscriptionEngine()),
            model: InstalledModel(id: "preview", displayName: "Preview", sizeBytes: 0,
                                  url: URL(fileURLWithPath: "/nonexistent")),
            options: TranscribeOptions(), sensitivity: 0.5, micDeviceUID: nil)
        session.record = record
        session.phase = phase
        session.systemAudio = systemAudio
        session.pendingChunks = pendingChunks
        // Something on the pill's meter, still.
        if phase == .recording { session.micLevel = 0.5 }
        return session
    }
    #endif

    public var isActive: Bool { phase == .starting || phase == .recording }
    public var elapsed: TimeInterval {
        (record.endDate ?? now()).timeIntervalSince(record.startDate)
    }

    // MARK: Starting and stopping

    /// Opens both streams. The microphone failing fails the meeting; the
    /// system audio failing leaves it running on the microphone, and says so.
    public func start() async {
        guard phase == .starting else { return }
        save()

        let deliver: @Sendable (MeetingSpeaker, [SpeechChunk]) -> Void = { [weak self] speaker, chunks in
            Task { @MainActor [weak self] in
                for chunk in chunks { self?.transcribe(chunk, from: speaker) }
            }
        }
        micFeed.onChunks = { deliver(.me, $0) }
        systemFeed.onChunks = { deliver(.others, $0) }
        if diarizer != nil || keepsAudio {
            // No file, no voices: the meeting is still Me and Others.
            recording = try? StreamRecording()
            systemFeed.recording = recording
        }
        if keepsAudio {
            micRecording = try? StreamRecording()
            micFeed.recording = micRecording
        }
        microphone.onSamples = { [micFeed] in micFeed.append($0) }
        (microphone as? MeetingMicrophone)?.recorder.onFailure = { [weak self] error in
            self?.microphoneProblem = error.localizedDescription
        }
        (microphone as? MeetingMicrophone)?.recorder.onLevel = { [weak self] level in
            self?.micLevel = level
        }
        (microphone as? MeetingMicrophone)?.recorder.onBands = { [weak self] bands in
            self?.micBands = bands
        }
        systemRecorder.onSamples = { [systemFeed] in systemFeed.append($0) }

        // Opening hardware takes a moment and blocks; not on the main actor.
        let microphone = microphone, systemRecorder = systemRecorder
        let micResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            Result { try microphone.start() }
        }.value
        // Stop may have been pressed while the hardware woke: `stop` has run
        // and the feeds are closed. Whatever opened since is let go again —
        // otherwise the window says "recording" over a live microphone whose
        // every sample is thrown away.
        guard phase == .starting else {
            await Task.detached { microphone.stop() }.value
            return
        }
        if case .failure(let error) = micResult {
            discardRecording()
            phase = .failed(error.localizedDescription)
            return
        }

        let systemResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            Result { try systemRecorder.start() }
        }.value
        guard phase == .starting else {
            await Task.detached {
                microphone.stop()
                systemRecorder.stop()
            }.value
            return
        }
        switch systemResult {
        case .success: systemAudio = .listening
        case .failure(let error): systemAudio = .unavailable(error.localizedDescription)
        }

        phase = .recording
        watchSystemAudio()
    }

    /// Stops listening, transcribes what is left, writes the summary, and
    /// saves. Returns once the file is final.
    public func stop(summarizing: Bool = true) async {
        guard isActive else { return }
        phase = .finishing
        silenceCheck?.cancel()

        let microphone = microphone, systemRecorder = systemRecorder
        await Task.detached(priority: .userInitiated) {
            microphone.stop()
            systemRecorder.stop()
        }.value
        // Chunks cut in the last moments hop to the main actor on their way
        // here; let them arrive before the feeds are closed behind them.
        try? await Task.sleep(for: .milliseconds(100))
        transcribe(micFeed.finish(), from: .me)
        transcribe(systemFeed.finish(), from: .others)
        record.endDate = now()
        save()

        // New ones are not started now that both feeds are finished.
        while let next = transcriptions.values.first {
            await next.value
        }

        await identifyVoices()
        await keepAudio()
        discardRecording()

        if summarizing, let summarize, !record.lines.isEmpty {
            phase = .summarizing
            record.summary = await summarize(record)
            if titleIsPlaceholder, let summary = record.summary, let suggestTitle,
               let title = await suggestTitle(summary),
               titleIsPlaceholder {     // not typed over while the model thought
                record.title = title
                titleIsPlaceholder = false
            }
        }
        phase = .finished
        save()
    }

    /// Tells the others' voices apart from the recording of the call, puts
    /// each of their lines on its voice, asks whose the voices are — and
    /// deletes the recording, whatever came of it. A meeting where this
    /// fails at any step is what it was before: Me and Others.
    private func identifyVoices() async {
        guard let recording, let diarizer,
              record.lines.contains(where: { $0.speaker == .others }) else { return }
        phase = .identifying
        recording.close()
        guard recording.isComplete,
              var diarization = try? await diarizer.diarize(recording: recording.url) else { return }
        // More voices than people invited: a few words of someone's the
        // model set apart are given back to them.
        let invited = SpeakerRoster(attendees: record.attendees).others.count
        if invited > 0 { diarization = diarization.folded(to: invited) }
        // A line two people spoke in becomes a line each, before either
        // is given a voice.
        record.lines = SpeakerAssignment.split(lines: record.lines, diarization: diarization)
        let numbered = SpeakerAssignment.number(lines: record.lines, diarization: diarization)
        record.assignVoices(numbered.lines)
        guard !record.voiceNumbers.isEmpty else { return }
        save()

        // The voiceprints, under the numbers the transcript uses.
        let speaking = diarization.speakingSeconds
        var samples: [Int: VoiceSample] = [:]
        for (speaker, voice) in numbered.voices {
            guard let vector = diarization.voiceprints[speaker] else { continue }
            samples[voice] = VoiceSample(vector: vector, seconds: speaking[speaker] ?? 0)
        }
        let voices = IdentifiedVoices(samples: samples, space: diarization.space)
        if let nameVoices {
            for (voice, name) in await nameVoices(record, voices) {
                record.name(voice: voice, as: name, confirmed: false)
            }
            save()
        }
        await voicesIdentified?(record, voices)
    }

    /// Both sides, as audio beside the notes, when Settings asks for it.
    /// A side that could not be written is left out; the other is kept.
    private func keepAudio() async {
        guard keepsAudio, let meeting = fileURL else { return }
        let sides: [(MeetingAudio.Side, StreamRecording?)] = [(.me, micRecording), (.others, recording)]
        for (side, recording) in sides {
            guard let recording else { continue }
            recording.close()
            guard recording.isComplete else { continue }
            let source = recording.url, destination = MeetingAudio.url(for: meeting, side: side)
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try MeetingAudio.encode(recording: source, to: destination)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { saveProblem = "The audio could not be kept: \(failure)" }
        }
    }

    private func discardRecording() {
        systemFeed.recording = nil
        micFeed.recording = nil
        recording?.discard()
        recording = nil
        micRecording?.discard()
        micRecording = nil
    }

    /// Stops without transcribing what is left, for quitting.
    public func abandon() {
        guard phase != .finished else { return }
        discardRecording()
        silenceCheck?.cancel()
        microphone.stop()
        systemRecorder.stop()
        for task in transcriptions.values { task.cancel() }
        record.endDate = record.endDate ?? now()
        phase = .finished
        save()
    }

    // MARK: Editing

    public func setTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.title else { return }
        record.title = trimmed
        titleIsPlaceholder = false
        save()
    }

    /// The user says whose a voice is. An empty name takes it back to
    /// "Speaker 2".
    public func nameVoice(_ voice: Int, as name: String) {
        guard record.name(voice: voice, as: name, confirmed: true) else { return }
        save()
    }

    public func setNotes(_ notes: String) {
        guard notes != record.notes else { return }
        record.notes = notes
        save()
    }

    /// Carries on from notes that were already written — for an event, by
    /// hand, with nothing recorded: their title, their text, who was
    /// invited and the event they belong to, in the file they are in. The
    /// recording becomes part of those notes instead of a second meeting
    /// beside them. Before `start`.
    public func adopt(_ existing: MeetingRecord, at url: URL) {
        record.title = existing.title
        titleIsPlaceholder = false
        record.notes = existing.notes
        record.attendees = existing.attendees
        record.joinURL = existing.joinURL
        record.eventID = existing.eventID
        // The file is this meeting's from here on: written over, and
        // renamed for the time the recording starts.
        fileURL = url
        save()
    }

    /// Takes the title, attendees and link from a calendar event.
    public func apply(_ event: MeetingEvent) {
        record.title = event.title
        titleIsPlaceholder = false
        record.attendees = event.attendees
        record.joinURL = event.joinURL
        record.eventID = event.id
        save()
    }

    // MARK: Transcribing

    private func transcribe(_ chunks: [SpeechChunk], from speaker: MeetingSpeaker) {
        for chunk in chunks { transcribe(chunk, from: speaker) }
    }

    private func transcribe(_ chunk: SpeechChunk, from speaker: MeetingSpeaker) {
        let id = UUID()
        pendingChunks += 1
        let queue = queue, model = currentModel?() ?? model, options = options
        transcriptions[id] = Task { [weak self] in
            let text: String
            var segments: [Transcript.Segment] = []
            var failure: Error?
            do {
                let transcript = try await queue.transcribe(samples: chunk.samples, options: options,
                                                            model: model, priority: .meeting)
                text = transcript.text
                segments = transcript.segments
            } catch {
                text = ""
                failure = error
            }
            guard let self else { return }
            if let failure, !(failure is CancellationError) {
                self.failedInARow += 1
                if self.failedInARow >= 2 {
                    self.transcriptionProblem = "Speech is not being transcribed: "
                        + failure.localizedDescription
                }
            } else {
                self.failedInARow = 0
                self.transcriptionProblem = nil
            }
            self.pendingChunks -= 1
            self.transcriptions[id] = nil
            let cleaned = Self.clean(text)
            if !cleaned.isEmpty {
                // The pieces it was written in, on the meeting's clock, for
                // dividing the line between voices when the meeting ends.
                let pieces = segments.compactMap { segment -> MeetingLine.Piece? in
                    let text = Self.clean(segment.text)
                    return text.isEmpty ? nil : MeetingLine.Piece(
                        start: chunk.start + segment.start, end: chunk.start + segment.end, text: text)
                }
                self.record.add(MeetingLine(speaker: speaker, start: chunk.start,
                                            end: chunk.end, text: cleaned,
                                            pieces: pieces.count > 1 ? pieces : nil))
                self.save()
            }
        }
    }

    /// What Whisper says about silence and music, which is not speech.
    static func clean(_ text: String) -> String {
        var result = text
        for noise in ["[BLANK_AUDIO]", "[NO_SPEECH]", "(blank audio)", "[MUSIC]", "(music)",
                      "[Music]", "[ Silence ]", "[silence]", "(silence)"] {
            result = result.replacingOccurrences(of: noise, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A chunk that is only punctuation or a lone filler is not a line.
        let letters = result.filter(\.isLetter)
        return letters.count < 2 ? "" : result
    }

    // MARK: Saving

    private func save() {
        do {
            fileURL = try MeetingMarkdown.write(record, to: folder, replacing: fileURL)
            saveProblem = nil
        } catch {
            saveProblem = error.localizedDescription
        }
    }

    // MARK: Is the call coming through?

    /// For the whole meeting, what the call audio is doing. A refused
    /// permission is not an error — the tap runs and delivers silence — and
    /// so does a call where nobody has spoken yet. After twenty seconds of
    /// nothing the probe settles which: refused is said in the window, and a
    /// quiet call is left alone. A capture that went away with the output,
    /// and could not be picked up again, is said as it is rather than left
    /// saying "listening".
    private func watchSystemAudio() {
        guard systemAudio == .listening else { return }
        silenceCheck = Task { [weak self] in
            guard let grace = self?.silenceGrace else { return }
            try? await Task.sleep(for: grace)
            // What the probe said, once it has been asked.
            var verdict: SystemAudioProbe.Result?
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                if !self.systemRecorder.isCapturing {
                    self.systemAudio = .unavailable(
                        "The call's audio was lost when the sound output changed. "
                        + "It is picked up again when the output changes back.")
                } else if self.systemRecorder.hasHeardSound {
                    self.systemAudio = .listening
                } else {
                    if verdict == nil, let probe = self.probeSystemAudio {
                        verdict = await probe()
                        guard !Task.isCancelled, self.isActive else { return }
                    }
                    // Sound may have arrived while the probe ran.
                    if self.systemRecorder.hasHeardSound {
                        self.systemAudio = .listening
                    } else {
                        switch verdict {
                        case .allowed: self.systemAudio = .listening
                        case .refused: self.systemAudio = .refused
                        case .inconclusive, nil: self.systemAudio = .silent
                        }
                    }
                }
                try? await Task.sleep(for: self.silenceInterval)
            }
        }
    }
}

/// One stream's way from samples to chunks: its segmenter, behind a lock,
/// since samples arrive on the capture's own thread.
private final class StreamFeed: @unchecked Sendable {
    let speaker: MeetingSpeaker
    var onChunks: (@Sendable ([SpeechChunk]) -> Void)?
    /// Where the stream is written as it arrives, on the meeting's clock.
    /// Set before the first sample.
    var recording: StreamRecording? {
        get { lock.lock(); defer { lock.unlock() }; return _recording }
        set { lock.lock(); _recording = newValue; lock.unlock() }
    }
    private var _recording: StreamRecording?

    private let lock = NSLock()
    private var segmenter: SpeechSegmenter
    private let meetingStart: Date
    /// Where this stream's first sample falls in the meeting. The two
    /// streams open a few hundred milliseconds apart.
    private var origin: TimeInterval?
    /// Samples accounted for since `origin`, gaps included.
    private var accounted = 0
    private var suppressed = false
    private var finished = false

    private let now: @Sendable () -> Date

    init(speaker: MeetingSpeaker, meetingStart: Date,
         configuration: SpeechSegmenter.Configuration,
         now: @escaping @Sendable () -> Date) {
        self.speaker = speaker
        self.meetingStart = meetingStart
        self.now = now
        segmenter = SpeechSegmenter(configuration: configuration)
    }

    var isSuppressed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return suppressed }
        set { lock.lock(); suppressed = newValue; lock.unlock() }
    }

    func append(_ samples: [Float]) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let rate = AudioRecorder.sampleRate
        let arrivedAt = now().timeIntervalSince(meetingStart) - Double(samples.count) / rate
        if origin == nil {
            origin = max(0, arrivedAt)
            // The stream opened this long after the meeting began.
            _recording?.appendSilence(samples: Int((origin ?? 0) * rate))
        }
        var chunks: [SpeechChunk] = []
        // The tap sends nothing while nothing plays, so a stream's samples
        // are not its clock. A gap of more than half a second is real time
        // that passed, and the segmenter is told so.
        let expected = (origin ?? 0) + Double(accounted) / rate
        if arrivedAt - expected > 0.5 {
            let gap = Int((arrivedAt - expected) * rate)
            chunks += segmenter.skip(gap)
            accounted += gap
            _recording?.appendSilence(samples: gap)
        }
        // Silence in its place while dictating, so the timeline does not slip.
        let input = suppressed ? [Float](repeating: 0, count: samples.count) : samples
        chunks += segmenter.append(input)
        accounted += samples.count
        _recording?.append(input)
        chunks = shifted(chunks)
        let handler = onChunks
        lock.unlock()
        if !chunks.isEmpty { handler?(chunks) }
    }

    func finish() -> [SpeechChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return [] }
        finished = true
        return shifted(segmenter.finish())
    }

    /// Called under `lock`.
    private func shifted(_ chunks: [SpeechChunk]) -> [SpeechChunk] {
        let offset = origin ?? 0
        return chunks.map { SpeechChunk(samples: $0.samples, start: $0.start + offset) }
    }
}
