import Testing
import Foundation
@testable import ClioCore

/// What the user waits through between pressing the key and seeing the pill.
///
///     CLIO_INTEGRATION=1 swift test --filter StartupLatency
private let enabled = ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil

@Suite("StartupLatency", .enabled(if: enabled), .serialized)
struct StartupLatency {

    private func milliseconds(_ block: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try block()
        return Double((ContinuousClock.now - start).components.attoseconds) / 1e15
    }

    @Test("How long does starting capture actually take?")
    func startCost() async throws {
        // Warm up: the very first engine start pays for lazy CoreAudio setup
        // that a real second recording never sees again.
        let warm = AudioRecorder()
        try? warm.start(maxSeconds: 600)
        _ = warm.stop()

        var warmBreakdown: [(phase: String, milliseconds: Double)] = []
        var samples: [Double] = []
        for _ in 0..<5 {
            let recorder = AudioRecorder()
            let elapsed = try milliseconds { try recorder.start(maxSeconds: 600) }
            _ = recorder.stop()
            samples.append(elapsed)
            warmBreakdown = recorder.startBreakdown
            try await Task.sleep(for: .milliseconds(120))
        }

        let worst = samples.max() ?? 0
        let median = samples.sorted()[samples.count / 2]
        print(String(format: "[latency] recorder.start() median %.1f ms, worst %.1f ms",
                     median, worst))

        // The buffer alone, for comparison — it is the part that scales with
        // the recording cap.
        for (phase, ms) in warmBreakdown {
            print(String(format: "[latency]   %-14s %6.1f ms", (phase as NSString).utf8String!, ms))
        }

        let allocation = milliseconds {
            var buffer = [Float](repeating: 0, count: Int(600 * AudioRecorder.sampleRate))
            buffer[buffer.count - 1] = 1
        }
        print(String(format: "[latency]   of which buffer allocation %.1f ms", allocation))
        print(String(format: "[latency] plus the %.0f ms push-to-talk hold threshold",
                     0.18 * 1000))
        print(String(format: "[latency] → the pill appears roughly %.0f ms after the key goes down",
                     180 + median))
    }
}
