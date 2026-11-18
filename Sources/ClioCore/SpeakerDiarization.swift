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

    /// A voice folded into another is one that spoke for less than this
    /// share of the least any voice kept did.
    static let foldShare = 0.25
    /// …and whose print is nearer than this to the voice it joins. Under
    /// the closest two different people Biscotti measured (0.62), over the
    /// one split of a single voice seen here (0.52). Not measured on a
    /// real call.
    static let foldDistance: Float = 0.60

    /// The same, with no more voices than `count` where that can be had
    /// without joining two people: the voices that spoke most are kept,
    /// and each of the rest joins the kept voice it sounds most like — if
    /// it said little beside them and does sound like one. A diarizer
    /// splits a few short words off a voice ("Nice.", "Oh, goodness.")
    /// far more readily than it hears a person who is not there, and the
    /// invitation says how many there are. A voice that fails either test
    /// is left: somebody may have joined who was not invited.
    public func folded(to count: Int) -> Diarization {
        let speaking = speakingSeconds.filter { $0.value >= SpeakerAssignment.leastSpeakingSeconds }
        guard count >= 1, speaking.count > count else { return self }
        // Most first; between equals the lower number, so the answer does
        // not depend on the order of a dictionary.
        let order = speaking.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.map(\.key)
        let kept = order.prefix(count)
        let least = kept.map { speaking[$0] ?? 0 }.min() ?? 0

        var into: [Int: Int] = [:]
        for extra in order.dropFirst(count) {
            guard (speaking[extra] ?? 0) < least * Self.foldShare,
                  let print = voiceprints[extra] else { continue }
            let nearest = kept.compactMap { voice in
                voiceprints[voice].map { (voice, VoiceprintMath.distance(print, $0)) }
            }.min { ($0.1, $0.0) < ($1.1, $1.0) }
            if let nearest, nearest.1 < Self.foldDistance { into[extra] = nearest.0 }
        }
        guard !into.isEmpty else { return self }

        var result = self
        result.spans = spans.map { span in
            var span = span
            if let voice = into[span.speaker] { span.speaker = voice }
            return span
        }
        for extra in into.keys { result.voiceprints[extra] = nil }
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
    /// A piece of a line goes to another voice only when that voice is
    /// heard in it for this long; less is the edge of someone's turn.
    static let leastPieceOverlap: TimeInterval = 0.4
    /// A run of pieces shorter than this is not a turn of its own: it
    /// stays with the turn before it.
    static let leastTurnSeconds: TimeInterval = 1.0

    /// `lines`, with any of the others' lines that two voices spoke in
    /// divided into one line for each turn.
    ///
    /// A line is a chunk of speech cut at pauses, up to twenty-five
    /// seconds, and two people who do not pause between them share one.
    /// The speech model writes a chunk in pieces — a sentence or so, each
    /// with its own time — so a line can be divided where one piece is one
    /// voice's and the next another's, without knowing when each word was
    /// said. A line with no pieces, or all of one voice, is left as it is.
    public static func split(lines: [MeetingLine], diarization: Diarization) -> [MeetingLine] {
        let speaking = diarization.speakingSeconds
        let spans = diarization.spans.filter { (speaking[$0.speaker] ?? 0) >= leastSpeakingSeconds }
        var result: [MeetingLine] = []
        for line in lines {
            guard line.speaker == .others, let pieces = line.pieces, pieces.count > 1 else {
                result.append(line)
                continue
            }
            // Whose each piece is; nil where nobody is heard in it enough.
            var owners: [Int?] = pieces.map { piece in
                var shares: [Int: TimeInterval] = [:]
                for span in spans {
                    let overlap = min(piece.end, span.end) - max(piece.start, span.start)
                    if overlap > 0 { shares[span.speaker, default: 0] += overlap }
                }
                guard let best = shares.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }),
                      best.value >= leastPieceOverlap else { return nil }
                return best.key
            }
            // A piece nobody is heard in goes with the piece before it,
            // or — at the start — the one after.
            for index in owners.indices where owners[index] == nil {
                owners[index] = index > 0 ? owners[index - 1] : owners.first { $0 != nil } ?? nil
            }
            // Runs of one voice; a run too short to be a turn joins the
            // one before it.
            var runs: [(owner: Int?, pieces: [MeetingLine.Piece])] = []
            for (owner, piece) in zip(owners, pieces) {
                if let last = runs.last, last.owner == owner {
                    runs[runs.count - 1].pieces.append(piece)
                } else {
                    runs.append((owner, [piece]))
                }
            }
            var turns: [(owner: Int?, pieces: [MeetingLine.Piece])] = []
            for run in runs {
                let length = run.pieces.reduce(0) { $0 + max(0, $1.end - $1.start) }
                if length < leastTurnSeconds, !turns.isEmpty {
                    turns[turns.count - 1].pieces += run.pieces
                } else if let last = turns.last, last.owner == run.owner {
                    turns[turns.count - 1].pieces += run.pieces
                } else {
                    turns.append(run)
                }
            }
            guard turns.count > 1 else {
                result.append(line)
                continue
            }
            for (index, turn) in turns.enumerated() {
                result.append(MeetingLine(
                    // The first keeps the line's own id; the rest are new lines.
                    id: index == 0 ? line.id : UUID(),
                    speaker: .others,
                    start: turn.pieces.first?.start ?? line.start,
                    end: turn.pieces.last?.end ?? line.end,
                    text: turn.pieces.map(\.text).joined(separator: " "),
                    pieces: turn.pieces))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

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
