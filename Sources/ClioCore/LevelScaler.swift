import Foundation

/// Turns the raw RMS of the last audio buffer into the 0…1 the meter draws.
///
/// Speech is quiet in absolute terms — a conversational voice into a laptop
/// microphone sits around -30 to -20 dBFS, with the gaps between words near
/// -50 — so a linear map of the whole -60…0 range put every word in one
/// narrow band a third of the way up and the bars barely moved. The window is
/// narrower here: silence at the bottom, and a ceiling that rises to the
/// loudest thing heard so far and sinks back afterwards. That way the meter
/// swings through most of its range whatever the microphone's gain, without
/// room noise filling it while nobody is speaking.
public struct LevelScaler: Sendable, Equatable {
    /// At or below this the bars sit at their floor. Between-word silence.
    public static let silenceDB: Float = -50
    /// The ceiling can never sink below this, or a quiet room would fill the
    /// meter on its own. A normal word at -20 reaches four fifths of the way.
    public static let minimumCeilingDB: Float = -15
    /// How fast the ceiling falls back after a loud word, so one shout does
    /// not leave the next sentence looking small.
    public static let decayDBPerSecond: Float = 10

    /// This instance's window. The defaults suit the whole signal; a single
    /// frequency band of it is quieter and gets a lower pair.
    public let silenceDB: Float
    public let minimumCeilingDB: Float

    public private(set) var ceilingDB: Float

    public init(silenceDB: Float = LevelScaler.silenceDB,
                minimumCeilingDB: Float = LevelScaler.minimumCeilingDB) {
        self.silenceDB = silenceDB
        self.minimumCeilingDB = minimumCeilingDB
        ceilingDB = minimumCeilingDB
    }

    /// The level for a buffer of the given RMS, `dt` seconds after the last.
    public mutating func level(rms: Float, dt: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        ceilingDB = max(minimumCeilingDB,
                        max(db, ceilingDB - Self.decayDBPerSecond * dt))
        let span = ceilingDB - silenceDB
        return min(1, max(0, (db - silenceDB) / span))
    }
}
