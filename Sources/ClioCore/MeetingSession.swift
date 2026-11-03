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
        /// Writing the summary.
        case summarizing
        case finished
        case failed(String)
    }

    /// What is coming from the other side of the call.
    public enum SystemAudioStatus: Equatable, Sendable {
        case starting
        case listening
        /// Running, but nothing but silence so far — which is also what a
        /// refused permission sounds like.
        case silent
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

    /// Run after the last chunk is in, to write the summary. Nil skips it.
    public var summarize: ((MeetingRecord) async -> String?)?

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
        microphone.onSamples = { [micFeed] in micFeed.append($0) }
        (microphone as? MeetingMicrophone)?.recorder.onFailure = { [weak self] error in
            self?.microphoneProblem = error.localizedDescription
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

        if summarizing, let summarize, !record.lines.isEmpty {
            phase = .summarizing
            record.summary = await summarize(record)
        }
        phase = .finished
        save()
    }

    /// Stops without transcribing what is left, for quitting.
    public func abandon() {
        guard phase != .finished else { return }
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
        save()
    }

    public func setNotes(_ notes: String) {
        guard notes != record.notes else { return }
        record.notes = notes
        save()
    }

    /// Takes the title, attendees and link from a calendar event.
    public func apply(_ event: MeetingEvent) {
        record.title = event.title
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
            var failure: Error?
            do {
                text = try await queue.transcribe(samples: chunk.samples, options: options,
                                                  model: model, priority: .meeting).text
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
                self.record.add(MeetingLine(speaker: speaker, start: chunk.start,
                                            end: chunk.end, text: cleaned))
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
    /// permission is not an error — the tap runs and delivers silence — so
    /// twenty seconds of nothing at all is worth a word in the window; and
    /// a capture that went away with the output, and could not be picked up
    /// again, is said as it is rather than left saying "listening".
    private func watchSystemAudio() {
        guard systemAudio == .listening else { return }
        silenceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                if !self.systemRecorder.isCapturing {
                    self.systemAudio = .unavailable(
                        "The call's audio was lost when the sound output changed. "
                        + "It is picked up again when the output changes back.")
                } else {
                    self.systemAudio = self.systemRecorder.hasHeardSound ? .listening : .silent
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// One stream's way from samples to chunks: its segmenter, behind a lock,
/// since samples arrive on the capture's own thread.
private final class StreamFeed: @unchecked Sendable {
    let speaker: MeetingSpeaker
    var onChunks: (@Sendable ([SpeechChunk]) -> Void)?

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
        if origin == nil { origin = max(0, arrivedAt) }
        var chunks: [SpeechChunk] = []
        // The tap sends nothing while nothing plays, so a stream's samples
        // are not its clock. A gap of more than half a second is real time
        // that passed, and the segmenter is told so.
        let expected = (origin ?? 0) + Double(accounted) / rate
        if arrivedAt - expected > 0.5 {
            let gap = Int((arrivedAt - expected) * rate)
            chunks += segmenter.skip(gap)
            accounted += gap
        }
        // Silence in its place while dictating, so the timeline does not slip.
        let input = suppressed ? [Float](repeating: 0, count: samples.count) : samples
        chunks += segmenter.append(input)
        accounted += samples.count
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
