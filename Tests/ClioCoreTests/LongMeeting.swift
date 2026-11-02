import Darwin
import Foundation
import Testing
import WhisperKit
@testable import ClioCore

/// An hour of meeting through a real session and the real model: does the
/// transcript keep up, and does memory stay flat?
///
///     CLIO_LONG_MEETING=60 swift test --filter LongMeeting
///
/// Uses a model already installed (CLIO_LONG_MEETING_MODEL, else the largest
/// one found) and downloads nothing. Paced by the transcript, not the clock:
/// each simulated minute goes in, then the test waits for the transcript to
/// catch up — so the wall time is how long an hour of meeting takes to
/// transcribe, and memory is what a real call holds, not a backlog no call
/// could build.
private let minutes = ProcessInfo.processInfo.environment["CLIO_LONG_MEETING"].flatMap(Int.init)

@MainActor
@Suite("LongMeeting", .enabled(if: minutes != nil), .serialized)
struct LongMeetingTests {

    private final class Source: MeetingAudioSource, @unchecked Sendable {
        var onSamples: (@Sendable ([Float]) -> Void)?
        var hasHeardSound = true
        func start() throws {}
        func stop() {}
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private func speak(_ text: String, voice: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-long-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-r", "175", "-o", file.path, text]
        try say.run()
        say.waitUntilExit()
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    private static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    @Test("An hour of meeting is transcribed faster than it is spoken, in flat memory")
    func anHour() async throws {
        let minutes = try #require(minutes)
        let manager = ModelManager()
        let wanted = ProcessInfo.processInfo.environment["CLIO_LONG_MEETING_MODEL"]
        let model = try #require(
            manager.installed.first { $0.id == wanted }
                ?? manager.installed.max { $0.sizeBytes < $1.sizeBytes },
            "No model installed to test with")

        let theirs = try speak("""
            Let's go through the launch plan. The beta goes to testers on Thursday, \
            and marketing needs the screenshots by Wednesday so the page is ready. \
            Pricing stays where it is for the starter tier, but the team plan moves \
            to twelve dollars a seat. Support wants a week of notice before anything \
            changes, and legal still has to read the new terms. Can someone own the \
            release notes, and can we check the numbers again on Monday?
            """, voice: "Samantha")
        let mine = try speak("I'll write the release notes and send them round on Wednesday.",
                             voice: "Daniel")

        let mic = Source(), system = Source(), clock = Clock()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-long-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = MeetingSession(
            title: "Long meeting", folder: folder,
            queue: TranscriptionQueue(WhisperKitEngine()), model: model,
            options: TranscribeOptions(language: "en"), sensitivity: 0.5, micDeviceUID: nil,
            microphone: mic, systemAudio: system, now: { clock.now() })
        await session.start()

        func push(_ samples: [Float], to source: Source) {
            var index = 0
            while index < samples.count {
                let end = min(samples.count, index + 1024)
                clock.advance(Double(end - index) / AudioRecorder.sampleRate)
                source.onSamples?(Array(samples[index..<end]))
                index = end
            }
        }

        let began = ContinuousClock.now
        var baseline: Double?
        var peak: Double = 0
        for minute in 0..<minutes {
            // A minute: the call talks, a pause the tap sends nothing for,
            // then the user answers — and the rest of the minute is quiet.
            push(theirs, to: system)
            clock.advance(2)
            push(mine, to: mic)
            let used = Double(theirs.count + mine.count) / AudioRecorder.sampleRate + 2
            clock.advance(max(0, 60 - used))
            // Let the transcript catch up before the next minute.
            while session.pendingChunks > 1 { try await Task.sleep(for: .milliseconds(50)) }
            let resident = Self.residentMegabytes()
            if minute == 0 { baseline = resident }   // the model is loaded by now
            peak = max(peak, resident)
        }
        await session.stop(summarizing: false)
        let wall = (ContinuousClock.now - began).components.seconds

        let lines = session.record.lines
        let growth = peak - (baseline ?? peak)
        let report = """
            [long meeting] \(minutes) min of meeting with \(model.displayName): \
            transcribed in \(wall / 60) min \(wall % 60) s \
            (\(String(format: "%.2f", Double(wall) / Double(minutes * 60)))× real time); \
            \(lines.count) lines; memory \(Int(baseline ?? 0)) MB after the first minute, \
            peak \(Int(peak)) MB (+\(Int(growth)) MB)
            """
        print(report)
        FileHandle.standardError.write(Data((report + "\n").utf8))

        #expect(Double(wall) < Double(minutes * 60) / 2, "does not keep up with a meeting")
        #expect(growth < 300, "memory grows with the length of the meeting")
        #expect(lines.contains { $0.speaker == .others && $0.text.lowercased().contains("thursday") })
        #expect(lines.contains { $0.speaker == .me && $0.text.lowercased().contains("release notes") })
        // The last minute's lines are stamped near its time, not drifted.
        let last = try #require(lines.last)
        #expect(abs(last.start - Double((minutes - 1) * 60)) < 60)
    }
}
