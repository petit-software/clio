import Foundation
import Observation
import Sparkle

/// Auto-updates.
///
/// `SPUStandardUpdaterController` rather than a hand-rolled driver: it brings
/// Sparkle's own dialogs, which are the ones users already recognise from
/// every other Mac app that updates this way, and it is the path Sparkle
/// actually tests.
///
/// Updates are offered, never applied silently. Scribe is held open by a global
/// event tap and may be mid-dictation; relaunching underneath someone in the
/// middle of a sentence is worse than waiting for them to say yes.
@MainActor
@Observable
public final class UpdateManager {

    /// False while a check is already running, so the menu item can disable
    /// itself instead of starting a second one.
    public private(set) var canCheck = true

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    public init() {
        // startingUpdater: true schedules the background check described by
        // SUScheduledCheckInterval in Info.plist.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)

        observation = controller.updater.observe(\.canCheckForUpdates,
                                                 options: [.initial, .new]) {
            [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    /// The user asked. This shows "you're up to date" as well as an available
    /// update — a manual check that silently does nothing looks broken.
    public func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    public var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Nil until a check has run — worth showing so "Check for Updates" is not
    /// the only evidence the mechanism works.
    public var lastCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
