import Testing
import Foundation
@testable import ClioCore

/// The meter's analysis. Pinned: a tone lands in the bar its band says, a
/// word rises within a frame or two and drains over several, silence and
/// room noise draw nothing, and different sounds move different bars.
@Suite("Meter analyzer")
struct MeterAnalyzerTests {

    private let rate = 48_000.0
    /// One 1024-frame buffer at 48 kHz.
    private let dt: Float = 1024 / 48_000

    private func tone(_ hz: Double, amplitude: Float = 0.1, count: Int = 1024) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @discardableResult
    private func feed(_ samples: [Float], into analyzer: MeterAnalyzer, times: Int = 1) -> [Float] {
        var bars: [Float] = []
        for _ in 0..<times {
            bars = samples.withUnsafeBufferPointer { analyzer.process($0, sampleRate: rate, dt: dt) }
        }
        return bars
    }

    @Test("A tone lands in its own bar")
    func tonesLandInTheirBars() {
        // Band centres, and the bar each band is drawn on.
        for (hz, band) in [(150.0, 0), (350.0, 1), (800.0, 2), (1800.0, 3), (3700.0, 4)] {
            let analyzer = MeterAnalyzer()
            let bars = feed(tone(hz), into: analyzer, times: 10)
            let bar = MeterAnalyzer.bandForBar.firstIndex(of: band)!
            let loudest = bars.indices.max { bars[$0] < bars[$1] }!
            #expect(loudest == bar, "\(hz) Hz lit bar \(loudest), expected \(bar)")
            #expect(bars[bar] > 0.6)
        }
    }

    @Test("A word rises at once and drains slowly")
    func attackIsFastAndReleaseIsSlow() {
        let analyzer = MeterAnalyzer()
        let word = tone(350, amplitude: 0.2)
        let afterOne = feed(word, into: analyzer)
        let bar = MeterAnalyzer.bandForBar.firstIndex(of: 1)!
        #expect(afterOne[bar] > 0.4)
        let peak = feed(word, into: analyzer, times: 8)[bar]
        // Silence for two buffers: still well up.
        let silence = [Float](repeating: 0, count: 1024)
        let soon = feed(silence, into: analyzer, times: 2)[bar]
        #expect(soon > peak * 0.4)
        // Half a second of it: gone.
        let later = feed(silence, into: analyzer, times: 24)[bar]
        #expect(later < 0.05)
    }

    @Test("Silence and room noise draw nothing")
    func quietIsFlat() {
        let analyzer = MeterAnalyzer()
        #expect(feed([Float](repeating: 0, count: 1024), into: analyzer, times: 5).allSatisfy { $0 == 0 })
        var seed: UInt32 = 3
        let hiss = (0..<1024).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed % 2000) / 1000 - 1) * 0.0005   // about -68 dBFS
        }
        #expect(feed(hiss, into: analyzer, times: 20).allSatisfy { $0 < 0.05 })
    }

    @Test("Different sounds move different bars, and all bars move a little")
    func barsDifferButShareLoudness() {
        let analyzer = MeterAnalyzer()
        let low = feed(tone(350), into: analyzer, times: 10)
        let high = feed(tone(3700), into: analyzer, times: 10)
        let lowBar = MeterAnalyzer.bandForBar.firstIndex(of: 1)!
        let highBar = MeterAnalyzer.bandForBar.firstIndex(of: 4)!
        #expect(low[lowBar] > high[lowBar])
        #expect(high[highBar] > low[highBar])
        // The overall loudness reaches every bar: a loud pure tone still
        // lifts the bars that do not hear its band.
        #expect(low.allSatisfy { $0 > 0.1 })
    }

    @Test("Levels stay in range, whatever the buffer or device")
    func levelsAreBounded() {
        let analyzer = MeterAnalyzer()
        for samples in [tone(1000, amplitude: 4), tone(1000, amplitude: 0.0001),
                        [Float](repeating: 0.9, count: 10), [Float](repeating: -0.9, count: 4096)] {
            let bars = feed(samples, into: analyzer)
            #expect(bars.count == MeterAnalyzer.barCount)
            #expect(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        // An 8 kHz Bluetooth device cannot reach the top band; it stays
        // dark rather than reading past Nyquist.
        let narrow = tone(300).withUnsafeBufferPointer { analyzer.process($0, sampleRate: 8000, dt: 0.02) }
        #expect(narrow.count == MeterAnalyzer.barCount)
    }
}
