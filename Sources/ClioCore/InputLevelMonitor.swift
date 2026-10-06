import Foundation

/// The microphone's level outside a dictation — what Settings shows.
///
/// The level used to come from the dictation alone, so the bar in Settings
/// sat still unless the shortcut was being held while looking at it, and
/// said nothing about whether the chosen microphone worked. This listens for
/// no other purpose than to draw that bar: a recorder with a one-second
/// buffer it is content to overflow.
///
/// Everything that touches the hardware runs on one queue, in order. What is
/// asked for is only written down; the queue then makes it so, however many
/// times the answer changed while a microphone was still waking.
public final class InputLevelMonitor: @unchecked Sendable {

    public enum Status: Sendable, Equatable {
        case off
        case starting
        case listening
        /// The microphone would not open, and why. This is the first place
        /// a broken microphone can be seen without losing a dictation to it.
        case failed(String)
    }

    /// Called ~30×/s on the main actor while listening, and once with zero
    /// when it stops.
    @MainActor public var onLevel: ((Float) -> Void)?
    @MainActor public var onStatus: ((Status) -> Void)?

    private enum Target: Equatable {
        case off
        /// Nil follows the system default.
        case device(String?)
    }

    private let recorder = AudioRecorder()
    private let queue = DispatchQueue(label: "com.bartbak.clio.level-monitor",
                                      qos: .userInitiated)
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var wanted = Target.off
    /// Touched only on `queue`.
    private var running = Target.off
    @MainActor private var isWired = false

    public init() {}

    /// Listen to this microphone, or to the system default for nil. Asking
    /// again for another one moves over to it.
    @MainActor
    public func listen(to deviceUID: String?) {
        if !isWired {
            isWired = true
            recorder.onLevel = { [weak self] level in self?.onLevel?(level) }
            recorder.onFailure = { [weak self] error in
                self?.captureFailed(error.localizedDescription)
            }
        }
        want(.device(deviceUID))
    }

    @MainActor
    public func stop() {
        want(.off)
    }

    /// Returns once the microphone has been let go, if `stop` was the last
    /// thing asked. Waits on the hardware, so not for the main actor.
    public func waitUntilSettled() {
        queue.sync {}
    }

    private func want(_ target: Target) {
        lock.lock()
        wanted = target
        lock.unlock()
        queue.async { [weak self] in self?.reconcile() }
    }

    private func reconcile() {
        lock.lock()
        let target = wanted
        lock.unlock()
        guard target != running else { return }

        if running != .off {
            recorder.stop()
            running = .off
        }
        guard case .device(let uid) = target else {
            publish(.off)
            return
        }

        publish(.starting)
        do {
            try recorder.start(maxSeconds: 1, deviceUID: uid)
            running = target
            publish(.listening)
        } catch {
            // Left as it is until something is asked again: a microphone that
            // will not open is not going to on the next tick either.
            publish(.failed(error.localizedDescription))
        }
    }

    /// The recorder gave up partway through.
    @MainActor
    private func captureFailed(_ reason: String) {
        queue.async { [weak self] in
            guard let self, self.running != .off else { return }
            self.recorder.stop()
            self.running = .off
            self.publish(.failed(reason))
        }
    }

    /// Through the main queue rather than a task, so statuses arrive in the
    /// order they happened.
    private func publish(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onStatus?(status)
            }
        }
    }
}
