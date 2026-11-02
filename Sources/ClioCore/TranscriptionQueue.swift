import Foundation

/// Who is waiting for a transcription.
public enum TranscriptionPriority: Sendable {
    /// Someone is holding a key and watching a pill: first, always.
    case dictation
    /// A meeting chunk. Minutes behind is fine; seconds behind a dictation
    /// is not.
    case meeting
}

/// One engine, used by two callers, one job at a time.
///
/// The engine is an actor, but an actor is re-entered at every `await`, and
/// `WhisperKit.transcribe` awaits all the way through. Two calls would run on
/// the one pipeline at once — and a meeting holds a stream of them. So every
/// call waits its turn here, and a dictation jumps ahead of any meeting
/// chunks that are waiting: the one already running finishes (CoreML cannot
/// be interrupted), and the dictation is next. Chunks are at most 25
/// seconds, so that is the longest a dictation ever waits.
///
/// Loading goes through the queue too. Switching models while a chunk is
/// mid-transcription would pull the model out from under it.
public actor TranscriptionQueue: TranscriptionEngine {
    private let engine: any TranscriptionEngine
    private var isBusy = false
    private var dictationWaiting: [CheckedContinuation<Void, Never>] = []
    private var meetingWaiting: [CheckedContinuation<Void, Never>] = []

    public init(_ engine: any TranscriptionEngine) {
        self.engine = engine
    }

    /// Meeting chunks waiting their turn, for the meeting window to say how
    /// far behind the transcript is.
    public var meetingBacklog: Int { meetingWaiting.count }

    public var isLoaded: Bool {
        get async { await engine.isLoaded }
    }

    public func load(model: InstalledModel) async throws {
        await acquire(.dictation)
        defer { release() }
        try await engine.load(model: model)
    }

    public func unload() async {
        await acquire(.dictation)
        defer { release() }
        await engine.unload()
    }

    public func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript {
        try await transcribe(samples: samples, options: options, priority: .dictation)
    }

    public func transcribe(samples: [Float], options: TranscribeOptions,
                           priority: TranscriptionPriority) async throws -> Transcript {
        await acquire(priority)
        defer { release() }
        return try await engine.transcribe(samples: samples, options: options)
    }

    /// Loads `model` if needed and transcribes, as one turn — so nothing can
    /// switch the model between the two.
    public func transcribe(samples: [Float], options: TranscribeOptions,
                           model: InstalledModel,
                           priority: TranscriptionPriority) async throws -> Transcript {
        await acquire(priority)
        defer { release() }
        try await engine.load(model: model)
        return try await engine.transcribe(samples: samples, options: options)
    }

    // MARK: Turns

    private func acquire(_ priority: TranscriptionPriority) async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            switch priority {
            case .dictation: dictationWaiting.append(continuation)
            case .meeting: meetingWaiting.append(continuation)
            }
        }
        // Handed the turn directly by `release`; `isBusy` never went false.
    }

    private func release() {
        if !dictationWaiting.isEmpty {
            dictationWaiting.removeFirst().resume()
        } else if !meetingWaiting.isEmpty {
            meetingWaiting.removeFirst().resume()
        } else {
            isBusy = false
        }
    }
}
