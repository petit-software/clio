import Foundation

/// The state machine from §4.
///
/// ```
/// idle ──hotkey down──▶ recording ──hotkey up──▶ transcribing ──▶ injecting ──▶ idle
///   ▲                       │                        │               │
///   └────────── Esc ────────┴──────── Esc ───────────┘───────────────┘
/// ```
public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case injecting
    /// Terminal, shown briefly in the overlay before returning to idle.
    case finished(String)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .injecting: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// Every busy state is cancellable — §4.
    public var isCancellable: Bool { isBusy }

    public var overlayLabel: String {
        switch self {
        case .idle: return ""
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .injecting: return "Pasting…"
        case .finished: return "Copied"
        case .failed(let message): return message
        }
    }
}
