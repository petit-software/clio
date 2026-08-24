import Foundation

/// How far into a recording we are, and how close to its cap.
///
/// A value type in Core rather than a couple of computed properties on the
/// overlay, because this is the arithmetic behind the only warning a user gets
/// before being cut off, and it should be testable without an app around it.
public struct RecordingProgress: Sendable, Equatable {
    public var elapsed: TimeInterval
    public var limit: TimeInterval

    /// How long is left before the recording stops on its own.
    public var remaining: TimeInterval { max(0, limit - elapsed) }

    /// The last stretch, where the number worth showing is what is left rather
    /// than what has passed.
    public var isNearLimit: Bool { remaining <= Self.warningWindow }

    /// Long enough to finish a sentence and stop, short enough not to nag.
    public static let warningWindow: TimeInterval = 20

    public init(elapsed: TimeInterval = 0, limit: TimeInterval = 120) {
        self.elapsed = elapsed
        self.limit = limit
    }

    /// "1:23" — the elapsed time, or what remains once that is what matters.
    public var display: String {
        let value = isNearLimit ? remaining : elapsed
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// How the cap reads once it has ended a recording.
    public static func limitDescription(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 60
            ? String(format: "Stopped at the %d:%02d limit", total / 60, total % 60)
            : "Stopped at the \(total)s limit"
    }
}
