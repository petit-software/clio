import AppKit
import CoreGraphics

/// Calls back when the Mac wakes — from sleep, or just its displays — once
/// the user can actually see the screen.
///
/// Waking usually lands on the lock screen, and a panel shown there would
/// time out before anyone has typed their password. So a wake is noted, and
/// the panel waits for the unlock when the screen is locked.
@MainActor
final class WakeObserver {
    private let onWake: () -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingWake = false

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.didWake() }
        }
        // Not public API, but the one signal macOS gives for the lock screen
        // going away, and it has been stable for many releases.
        observe(DistributedNotificationCenter.default(),
                Notification.Name("com.apple.screenIsUnlocked")) { $0.didUnlock() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (WakeObserver) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    private func didWake() {
        pendingWake = true
        // The lock screen is not always up the instant the wake is reported.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, pendingWake, !Self.isScreenLocked else { return }
            fire()
        }
    }

    /// Only after a wake: locking and unlocking at the desk is not the start
    /// of anything.
    private func didUnlock() {
        guard pendingWake else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, pendingWake else { return }
            fire()
        }
    }

    private func fire() {
        pendingWake = false
        onWake()
    }

    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
