import Foundation

/// The maximum recording length, as the user sets it.
///
/// Stored in seconds because that is what the recorder and its buffer work in,
/// but chosen in minutes: the cap runs to ten of them, and nobody sets a
/// dictation limit to the second.
public enum RecordingLimit {

    public static let range: ClosedRange<Double> = 1...10

    public static func minutes(seconds: Double) -> Double {
        // Rounded and clamped, so a value written before this was in minutes —
        // or edited by hand — lands on a step the picker can actually show
        // rather than sticking between two.
        let whole = (seconds / 60).rounded()
        return min(range.upperBound, max(range.lowerBound, whole))
    }

    public static func seconds(minutes: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, minutes)) * 60
    }

    public static func label(seconds: Double) -> String {
        let value = Int(minutes(seconds: seconds))
        return value == 1 ? "1 minute" : "\(value) minutes"
    }
}
