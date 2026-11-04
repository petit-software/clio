import Foundation
import ClioCore

/// Settings ▸ Model's "Keep model in memory", honoured.
///
/// On, a speech model loaded for one dictation stays for the next, and a
/// summary model stays two minutes after its last request. Off, both are let
/// go as soon as nothing is using them — after a dictation however it ends,
/// after a meeting stops, and the moment the toggle is turned off. The cost
/// is the cold load the toggle's caption describes; the warm-up at key-down
/// hides part of it.
///
/// The toggle existed from the first commit and read nothing until this
/// file. `ModelResidency` in the tests is what showed the memory does come
/// back when the models are freed.
extension AppCoordinator {

    /// How long a summary model stays loaded after its last request.
    var summaryModelIdleTime: Duration {
        settingsStore.settings.keepModelInMemory ? .seconds(120) : .seconds(5)
    }

    /// Lets the speech model go if Settings says not to keep it and nothing
    /// is using it. A meeting uses it until it is finished; a dictation
    /// until it has ended, and the dictation's own end calls this again.
    func releaseModelsIfNotKept() {
        guard !settingsStore.settings.keepModelInMemory else { return }
        guard !state.isCancellable else { return }
        if let meeting {
            switch meeting.phase {
            case .finished, .failed: break
            default: return
            }
        }
        // The queue takes the dictation turn for it, so a chunk mid-flight
        // finishes first, and the next load — the warm-up at key-down —
        // waits behind it.
        Task { [engine] in await engine.unload() }
    }

    /// The toggle changed. Off: release now, and the summary models follow
    /// at the shorter idle time. On: nothing to free; the next key-down
    /// loads and the model stays from then.
    func modelResidencyChanged() {
        let idle = summaryModelIdleTime
        for model in localSummaryModels.values {
            Task { await model.setIdleTime(idle) }
        }
        releaseModelsIfNotKept()
    }
}
