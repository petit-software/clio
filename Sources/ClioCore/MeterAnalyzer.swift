import Accelerate
import Foundation

/// Turns the microphone signal into the five bars of the meter.
///
/// What a good voice meter does, and what this does:
///
/// - **Each bar hears a different part of the voice.** Five log-spaced bands
///   from 90 Hz to 5.2 kHz: the fundamental, the first formant where vowels
///   carry most of their energy, the upper formants, and the hiss of
///   consonants. The bars move differently because the sound does, not
///   because anything is added.
/// - **Loudness is judged on a log scale, against a moving reference.** The
///   reference tracks the recent peak of the whole signal and sinks slowly,
///   and every band reads its level over the same span below it — with a
///   fixed tilt so the upper bands, which speech leaves quieter, are not
///   permanently small. Quiet and loud speech both fill the meter, and the
///   bands keep their differences: a vowel and a consonant are different
///   pictures.
/// - **Fast up, slower down.** A syllable lands within a frame; it drains
///   over about a tenth of a second. That asymmetry is most of what makes a
///   meter read as responsive rather than nervous.
/// - **One gesture, not five.** A share of the overall loudness is mixed
///   into every bar, so the whole meter breathes with the voice while the
///   bars keep their differences.
/// - **A wave, not a row of gauges.** Each bar draws the voice a little
///   behind the tall one, so a syllable ripples outwards across the meter
///   over about a tenth of a second rather than landing everywhere at once.
/// - **Nothing in silence.** A gate on the overall level sends every bar to
///   its floor between words and in an empty room.
///
/// Called from the audio tap's thread with each hardware buffer, and only
/// from there: the ceilings and smoothers are state.
public final class MeterAnalyzer: @unchecked Sendable {
    public static let barCount = 5

    /// Band edges in Hz.
    public static let edges: [Double] = [90, 220, 520, 1200, 2600, 5200]

    /// Which band each bar draws, left to right. The design's silhouette is
    /// [0.31, 0.57, 0.18, 0.31, 0.18] of the height: the tallest bar takes
    /// the first-formant band, where speech keeps most of its energy, so the
    /// biggest bar makes the biggest move; the two short bars take the two
    /// highest bands, so consonants flick them; the fundamental and the
    /// upper formants take the remaining pair.
    public static let bandForBar: [Int] = [0, 1, 4, 2, 3]

    /// The DFT length: one hardware buffer at 48 kHz, ~21 ms.
    static let length = 1024

    // MARK: Tuning

    /// The dB span of the meter: from the reference at the top to nothing
    /// at the bottom. Speech modulates by 30–40 dB between the peak of a
    /// vowel and the gap after it, so this is what lets a syllable travel
    /// the whole bar and a sentence never sit pinned at the top.
    public static let rangeDB: Float = 38
    /// The reference sits this far above the recent peak: a normal word
    /// reaches about three quarters of the way up, and only a louder one
    /// touches the top.
    public static let headroomDB: Float = 7
    /// How many buffers behind the tall bar each bar draws. A syllable
    /// lands on the tall bar first and ripples outwards over about a tenth
    /// of a second, which is what makes the meter read as a wave rather
    /// than five gauges: the bars agree about the voice, a moment apart.
    static let delayBuffers: [Int] = [2, 0, 2, 4, 6]
    /// The reference never sinks below this, or room noise would fill the
    /// meter on its own. And it sinks slowly, so one shout does not leave
    /// the next sentence looking small for long.
    public static let minimumReferenceDB: Float = -28
    public static let referenceDecayDBPerSecond: Float = 6
    /// Speech gets quieter with frequency, about 6 dB an octave above the
    /// first formant. Added per band so the upper bars are not permanently
    /// small; the balance between bands still shifts with every sound.
    static let tiltDB: [Float] = [0, 0, 4, 9, 13]
    /// Time constants of each bar's rise and fall, in seconds to ~63%.
    public static let attack: Float = 0.015
    public static let release: Float = 0.09
    /// Overall level below which nothing is drawn.
    public static let gateDB: Float = -58
    /// How much of each bar is the overall loudness rather than its band.
    public static let blend: Float = 0.25
    /// A gentle lift so mid-level speech sits mid-meter.
    public static let gamma: Float = 0.85

    // MARK: State

    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private var realIn = [Float](repeating: 0, count: length)
    private var imagIn = [Float](repeating: 0, count: length)
    private var realOut = [Float](repeating: 0, count: length)
    private var imagOut = [Float](repeating: 0, count: length)
    private var magnitudes = [Float](repeating: 0, count: length / 2)

    private var reference: Float = minimumReferenceDB
    private var smoothed = [Float](repeating: 0, count: barCount)
    private var overallSmoothed: Float = 0
    /// Recent smoothed values, newest last, for the delays.
    private var history: [(overall: Float, bands: [Float])] = []

    /// The bars as of the last buffer, 0…1 each.
    public private(set) var bars = [Float](repeating: 0, count: barCount)

    public init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.length), .FORWARD)!
        var window = [Float](repeating: 0, count: Self.length)
        vDSP_hann_window(&window, vDSP_Length(Self.length), Int32(vDSP_HANN_DENORM))
        self.window = window
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// Feed one buffer of samples at `sampleRate`, `dt` seconds after the
    /// previous one, and get the bars.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>,
                        sampleRate: Double,
                        dt: Float) -> [Float] {
        let n = Self.length
        let count = min(samples.count, n)
        guard count > 0, sampleRate > 0, let base = samples.baseAddress else {
            return bars
        }
        let dt = max(0.001, min(dt, 0.1))

        // Overall loudness first: it gates everything else.
        var meanSquare: Float = 0
        vDSP_measqv(base, 1, &meanSquare, vDSP_Length(count))
        let overallDB = 10 * log10(max(meanSquare, 1e-12))

        // Windowed DFT of the buffer (zero-padded if short).
        vDSP_vmul(base, 1, window, 1, &realIn, 1, vDSP_Length(count))
        if count < n {
            realIn.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: count).update(repeating: 0, count: n - count)
            }
        }
        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)
        realOut.withUnsafeMutableBufferPointer { real in
            imagOut.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Band powers in dB. Parseval, the mirrored half, and the Hann
        // window's coherent gain of one half: |X|² summed over a band, times
        // 2, over N², times 4.
        let binHz = sampleRate / Double(n)
        let scale = 8 / Float(n * n)
        var bandDB = [Float](repeating: -120, count: Self.barCount)
        for band in 0..<Self.barCount {
            let lo = max(1, Int(Self.edges[band] / binHz))
            let hi = min(n / 2, Int(Self.edges[band + 1] / binHz))
            guard hi > lo else { continue }   // past Nyquist on a narrow device
            var sumOfSquares: Float = 0
            magnitudes.withUnsafeBufferPointer {
                vDSP_svesq($0.baseAddress!.advanced(by: lo), 1, &sumOfSquares, vDSP_Length(hi - lo))
            }
            bandDB[band] = 10 * log10(max(sumOfSquares * scale, 1e-12))
        }

        let gated = overallDB < Self.gateDB

        // One reference for everything: the recent peak of the whole signal,
        // plus headroom. Per-band references made every vowel fill every
        // bar; a shared one keeps the bands' differences, which is the point.
        reference = max(Self.minimumReferenceDB,
                        max(overallDB, reference - Self.referenceDecayDBPerSecond * dt))
        let top = reference + Self.headroomDB
        let floor = top - Self.rangeDB

        let overallTarget = gated ? 0 : Self.shape((overallDB - floor) / Self.rangeDB)
        overallSmoothed = Self.follow(overallSmoothed, towards: overallTarget, dt: dt)

        for bar in 0..<Self.barCount {
            let band = Self.bandForBar[bar]
            let raw = gated ? 0 : Self.shape((bandDB[band] + Self.tiltDB[band] - floor) / Self.rangeDB)
            smoothed[bar] = Self.follow(smoothed[bar], towards: raw, dt: dt)
        }

        history.append((overallSmoothed, smoothed))
        let longest = Self.delayBuffers.max()!
        if history.count > longest + 1 { history.removeFirst(history.count - longest - 1) }

        for bar in 0..<Self.barCount {
            let index = max(0, history.count - 1 - Self.delayBuffers[bar])
            let then = history[index]
            bars[bar] = min(1, max(0, Self.blend * then.overall + (1 - Self.blend) * then.bands[bar]))
        }
        return bars
    }

    /// Clamp to 0…1 and apply the perceptual lift.
    private static func shape(_ x: Float) -> Float {
        pow(min(1, max(0, x)), gamma)
    }

    /// One step of a rise-fast, fall-slow smoother.
    private static func follow(_ current: Float, towards target: Float, dt: Float) -> Float {
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-dt / tau))
    }
}
