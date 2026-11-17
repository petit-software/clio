import Foundation

/// A stretch of the call in which one voice spoke.
public struct SpeakerSpan: Sendable, Equatable {
    /// The diarizer's own number for the voice; any integers, in no order.
    public var speaker: Int
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: Int, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Who spoke when on the other side of a call, and what each voice is like.
public struct Diarization: Sendable, Equatable {
    public var spans: [SpeakerSpan]
    /// One vector per voice, by the diarizer's number: the voice itself, as
    /// far as a model can say. A voice that was always talked over has none.
    public var voiceprints: [Int: [Float]]
    /// Which model made the voiceprints. Vectors from two models are not
    /// comparable, and are never compared.
    public var space: String

    public init(spans: [SpeakerSpan], voiceprints: [Int: [Float]] = [:], space: String = "") {
        self.spans = spans
        self.voiceprints = voiceprints
        self.space = space
    }

    /// Seconds each voice spoke.
    public var speakingSeconds: [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        for span in spans { result[span.speaker, default: 0] += max(0, span.end - span.start) }
        return result
    }
}

/// Arithmetic on voiceprints.
public enum VoiceprintMath {
    /// Cosine distance, 0…2: 0 the same direction, 1 at right angles, 2
    /// opposite. Not 0…1. A vector of zeros — no voice at all — is at 2
    /// from everything, never close to anything.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            aa += a[index] * a[index]
            bb += b[index] * b[index]
        }
        guard aa > 0, bb > 0 else { return 2 }
        return min(2, max(0, 1 - dot / (aa.squareRoot() * bb.squareRoot())))
    }
}

/// Tells the voices in a recording of the call apart.
public protocol SpeakerDiarizing: Sendable {
    /// `file` is what `StreamRecording` wrote: the call's side of the
    /// meeting, with the meeting's own clock.
    func diarize(recording file: URL) async throws -> Diarization
}

/// Which voice said each line: the lines of a transcript laid over the
/// spans of a diarization.
public enum SpeakerAssignment {

    /// A voice that spoke for less than this in the whole meeting is not a
    /// person: a cough, a notification, a second of crosstalk the model
    /// split off. Its lines go to whoever else spoke in them, or stay
    /// unassigned.
    static let leastSpeakingSeconds: TimeInterval = 1.5

    /// The voice of each of the others' lines, by line id, numbered 1, 2,
    /// 3… in the order the voices first speak in the transcript — so
    /// "Speaker 1" is whoever the reader meets first. A line no span
    /// overlaps is left out.
    ///
    /// A line takes the voice that spoke for most of it. Lines are a few
    /// seconds to twenty-five, cut at pauses, so most hold one voice; one
    /// that holds two goes to the longer share, which is wrong for the
    /// shorter and cannot be put right without knowing when each word was
    /// said.
    public static func assign(lines: [MeetingLine], diarization: Diarization) -> [UUID: Int] {
        number(lines: lines, diarization: diarization).lines
    }

    /// The same, with which of the diarizer's numbers became which voice —
    /// what its voiceprints are filed under.
    public static func number(lines: [MeetingLine], diarization: Diarization)
        -> (lines: [UUID: Int], voices: [Int: Int]) {
        let speaking = diarization.speakingSeconds
        let spans = diarization.spans.filter { (speaking[$0.speaker] ?? 0) >= leastSpeakingSeconds }

        var raw: [(id: UUID, start: TimeInterval, speaker: Int)] = []
        for line in lines where line.speaker == .others {
            var shares: [Int: TimeInterval] = [:]
            for span in spans {
                let overlap = min(line.end, span.end) - max(line.start, span.start)
                if overlap > 0 { shares[span.speaker, default: 0] += overlap }
            }
            // The larger share; between equals the lower number, so the
            // answer does not depend on the order of a dictionary.
            guard let best = shares.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })
            else { continue }
            raw.append((line.id, line.start, best.key))
        }

        var numbers: [Int: Int] = [:]
        var result: [UUID: Int] = [:]
        for entry in raw.sorted(by: { $0.start < $1.start }) {
            if numbers[entry.speaker] == nil { numbers[entry.speaker] = numbers.count + 1 }
            result[entry.id] = numbers[entry.speaker]
        }
        return (result, numbers)
    }
}

/// The call's side of a meeting, written to a file as it arrives, for the
/// one thing that needs all of it at once: telling the voices apart when
/// the meeting ends. Deleted as soon as that is done; a meeting's audio is
/// never kept.
///
/// 16 kHz mono, 16-bit, no header — 115 MB an hour. Time in the file is
/// time in the meeting: the stream's late start and the stretches the tap
/// sends nothing for are written as silence, so a span the diarizer finds
/// at 12:40 is a line stamped 12:40.
public final class StreamRecording: @unchecked Sendable {

    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var isClosed = false
    private var failed = false

    /// Where recordings go: a folder in the temporary directory, and in it
    /// one per running copy of Clio, named by process — so what a crash left
    /// behind can be told from what another copy is writing right now.
    public static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.bartbak.clio.meeting-audio", isDirectory: true)
    }

    public static var directory: URL {
        root.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// Removes the recordings of every copy of Clio that is no longer
    /// running. At launch: a meeting that did not end — a crash, a forced
    /// quit — does not get to keep its audio either.
    public static func removeLeftovers(in root: URL = StreamRecording.root,
                                       isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let pid = pid_t(folder.lastPathComponent),
               pid != ProcessInfo.processInfo.processIdentifier, isRunning(pid) { continue }
            if folder.lastPathComponent == "\(ProcessInfo.processInfo.processIdentifier)" { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    public init(directory: URL = StreamRecording.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(UUID().uuidString).pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { close() }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                out[index] = Int16(max(-1, min(1, sample)) * 32_767)
            }
        }
        write(data)
    }

    /// Time that passed with nothing to record.
    public func appendSilence(samples count: Int) {
        var left = count
        let block = Data(count: 32_000 * MemoryLayout<Int16>.size)
        while left > 0 {
            let now = min(left, 32_000)
            write(now == 32_000 ? block : Data(count: now * MemoryLayout<Int16>.size))
            left -= now
        }
    }

    private func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !failed else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A full disk: the meeting goes on without voices told apart.
            failed = true
        }
    }

    /// Whether everything given was written. False after a write failed.
    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !failed
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    /// Closes the file and deletes it.
    public func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The samples of a recording, as the diarizer takes them.
    public static func samples(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            for index in 0..<count { samples[index] = Float(input[index]) / 32_767 }
        }
        return samples
    }
}
