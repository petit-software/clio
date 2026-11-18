import Foundation
import WhisperKit

/// A recording made somewhere else, turned into a meeting: transcribed,
/// its voices told apart and named, summarized, and saved as Markdown
/// beside the others.
///
/// It is put through a `MeetingSession`, as a call would be — the file
/// stands in for the call's side, nothing stands in for the microphone, and
/// a clock that runs as fast as the file is read stands in for the time —
/// so an imported meeting is cut, transcribed, diarized, named, summarized
/// and written by the same code as one that was recorded, and comes out
/// the same. Every line is someone on the recording; none is "Me".
@MainActor
public enum MeetingImport {

    /// Stands in for a stream: `MeetingSession` starts it, and the import
    /// pushes the file's samples through it.
    final class Source: MeetingAudioSource, @unchecked Sendable {
        var onSamples: (@Sendable ([Float]) -> Void)?
        var hasHeardSound: Bool { true }
        func start() throws {}
        func stop() {}
    }

    /// The meeting's time while a file is read: the file's own date, moved
    /// on by exactly as much audio as has been given.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    public enum ImportError: LocalizedError {
        case unreadable(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return "The recording could not be read: \(reason)"
            case .empty: return "The recording has no sound in it."
            }
        }
    }

    /// When the recording was made, as far as the file says.
    static func date(of file: URL) -> Date {
        let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    /// The file as 16 kHz mono samples — any format macOS can decode.
    nonisolated static func samples(of file: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            do {
                return try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
            } catch {
                throw ImportError.unreadable(error.localizedDescription)
            }
        }.value
    }

    /// Imports `file`. `configure` is given the session before it starts —
    /// to set what a recorded meeting's would be set to: the diarizer, the
    /// namer, the summary. `progress` is called with how much of the file
    /// has been transcribed, 0…1, and then with the session's own phases to
    /// follow. Returns the finished session; its `fileURL` is the meeting.
    public static func run(file: URL, folder: URL, queue: TranscriptionQueue,
                           model: InstalledModel, options: TranscribeOptions, sensitivity: Double,
                           configure: (MeetingSession) -> Void,
                           progress: @escaping (Double) -> Void) async throws -> MeetingSession {
        let samples = try await samples(of: file)
        guard samples.contains(where: { $0 != 0 }) else { throw ImportError.empty }

        let clock = Clock(date(of: file))
        let source = Source()
        let session = MeetingSession(
            title: file.deletingPathExtension().lastPathComponent,
            folder: folder, queue: queue, model: model, options: options,
            sensitivity: sensitivity, micDeviceUID: nil,
            microphone: Source(), systemAudio: source, now: { clock.now() })
        configure(session)
        // The file is the audio; a copy of it beside the notes is not wanted.
        session.keepsAudio = false
        await session.start()
        if case .failed(let reason) = session.phase { throw ImportError.unreadable(reason) }

        // In blocks the size a capture delivers, ten seconds at a time, and
        // no faster than the transcript keeps up: the chunks waiting to be
        // transcribed are audio in memory.
        let rate = AudioRecorder.sampleRate
        let stride = Int(rate) * 10
        var index = 0
        while index < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, index + stride)
            var block = index
            while block < end {
                let next = min(end, block + 1_024)
                clock.advance(Double(next - block) / rate)
                source.onSamples?(Array(samples[block..<next]))
                block = next
            }
            index = end
            progress(Double(index) / Double(samples.count))
            await Task.yield()
            while session.pendingChunks > 2 {
                try Task.checkCancellation()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        await session.stop()
        return session
    }
}
