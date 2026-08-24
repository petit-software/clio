import AppKit

/// Start / stop / cancel sounds (§4).
///
/// macOS's own alert sounds rather than shipped assets: they are already on
/// every Mac, already match the system's character, and keep the bundle to a
/// binary and a JSON file. Instances are made once — building an NSSound on
/// the first keypress would put file I/O in the path we are trying to keep
/// short.
@MainActor
public final class FeedbackPlayer {

    public enum Cue: Sendable {
        case start
        case stop
        case cancel

        var systemSoundName: String {
            switch self {
            case .start: return "Tink"
            case .stop: return "Pop"
            case .cancel: return "Funk"
            }
        }
    }

    private var sounds: [String: NSSound] = [:]
    private let volume: Float

    public init(volume: Float = 0.35) {
        self.volume = volume
        for cue in [Cue.start, .stop, .cancel] {
            if let sound = NSSound(named: cue.systemSoundName) {
                sound.volume = volume
                sounds[cue.systemSoundName] = sound
            }
        }
    }

    public func play(_ cue: Cue, enabled: Bool) {
        guard enabled, let sound = sounds[cue.systemSoundName] else { return }
        // Restart rather than ignore: two quick dictations in a row should
        // each be audible.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
