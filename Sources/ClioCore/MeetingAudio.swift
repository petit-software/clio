import AVFoundation
import Foundation

/// Whether a meeting's audio is kept once the meeting is over.
public enum MeetingAudioRetention: String, Codable, Sendable, CaseIterable {
    /// Not at all: the default, and what Clio did before there was a choice.
    case off
    /// For thirty days, then deleted.
    case month
    case forever

    public var label: String {
        switch self {
        case .off: return "Never"
        case .month: return "For 30 days"
        case .forever: return "For good"
        }
    }

    /// Days the audio is kept; nil for no limit, or for not at all.
    public var days: Int? { self == .month ? 30 : nil }
}

/// A meeting's audio, where it is kept: two files beside its Markdown, one
/// per side of the call — `Weekly sync.me.m4a` and `Weekly sync.others.m4a`
/// — so who said what is still in the recording, and the notes are still
/// one file anything can open.
///
/// Both run on the meeting's clock, as the transcript does: second 754 of
/// either file is the line stamped 12:34. They belong to the Markdown file
/// and go where it goes — renamed with it, trashed with it.
public enum MeetingAudio {

    public enum Side: String, CaseIterable, Sendable {
        case me
        case others
    }

    /// AAC, mono, at the 16 kHz everything else here runs at. Speech at
    /// 32 kbps: about 14 MB an hour a side.
    static let bitRate = 32_000

    public static func url(for meeting: URL, side: Side) -> URL {
        meeting.deletingPathExtension().appendingPathExtension("\(side.rawValue).m4a")
    }

    /// The audio files a meeting has, by side.
    public static func files(for meeting: URL) -> [Side: URL] {
        var result: [Side: URL] = [:]
        for side in Side.allCases {
            let file = url(for: meeting, side: side)
            if FileManager.default.fileExists(atPath: file.path) { result[side] = file }
        }
        return result
    }

    /// The meeting's file was renamed: its audio takes the new name.
    public static func move(from old: URL, to new: URL) {
        guard old.standardizedFileURL != new.standardizedFileURL else { return }
        for (side, file) in files(for: old) {
            let destination = url(for: new, side: side)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: file, to: destination)
        }
    }

    /// To the Trash with the meeting, so Finder puts back all of it.
    public static func trash(for meeting: URL) {
        for file in files(for: meeting).values {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// Writes what `StreamRecording` recorded as AAC. A block at a time:
    /// an hour is 115 MB as it was recorded and is never all in memory.
    public static func encode(recording: URL, to destination: URL) throws {
        let rate = AudioRecorder.sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 1, interleaved: false) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: destination)
        let input = try FileHandle(forReadingFrom: recording)
        defer { try? input.close() }
        do {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                           AVSampleRateKey: rate,
                           AVNumberOfChannelsKey: 1,
                           AVEncoderBitRateKey: bitRate],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let block = 16_000 * 10
            while let data = try input.read(upToCount: block * MemoryLayout<Int16>.size), !data.isEmpty {
                let frames = data.count / MemoryLayout<Int16>.size
                guard frames > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let channel = buffer.floatChannelData?[0] else { break }
                data.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for index in 0..<frames { channel[index] = Float(samples[index]) / 32_767 }
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                try output.write(from: buffer)
            }
        } catch {
            // Half a file is worse than none: it plays, and stops early.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Deletes the audio in `folder` that is older than `days`, going by
    /// when each file was made. Only files named as Clio names them, so a
    /// recording of the user's own in the same folder is never touched.
    /// Returns how many went.
    @discardableResult
    public static func removeExpired(in folder: URL, olderThan days: Int, now: Date = Date()) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for url in urls where isMeetingAudio(url) {
            guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    static func isMeetingAudio(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return Side.allCases.contains { name.hasSuffix(".\($0.rawValue).m4a") }
    }
}
