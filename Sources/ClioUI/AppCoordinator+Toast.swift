import Foundation
import ClioCore

/// What the library window says, top right, about something just done from
/// a menu: copied, removed, moved to the Trash. A menu closes and leaves
/// nothing behind to say it worked; this is that.
public struct LibraryToast: Identifiable {
    public let id = UUID()
    /// An SF Symbol, filled.
    public var symbol: String
    public var message: String
    /// Whether what it reports can be taken back: Undo in place of ✕.
    public var canUndo: Bool
}

extension AppCoordinator {
    /// How long a toast stays.
    static let toastTime: TimeInterval = 5

    /// Shows a toast, in place of any that is up. With `undo` it offers
    /// Undo; `settle` runs when it goes without that — its time up, closed,
    /// or another taking its place — for whatever was put off until the
    /// thing could no longer be taken back.
    func showToast(symbol: String, _ message: String, seconds: TimeInterval = AppCoordinator.toastTime,
                   undo: (() -> Void)? = nil, settle: (() -> Void)? = nil) {
        dismissToast()
        let toast = LibraryToast(symbol: symbol, message: message, canUndo: undo != nil)
        self.toast = toast
        toastUndo = undo
        toastSettle = settle
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.dismissToast()
        }
    }

    /// ✕, the five seconds, or the next toast.
    public func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        let settle = toastSettle
        toastUndo = nil
        toastSettle = nil
        toast = nil
        settle?()
    }

    /// Undo: what the toast reported is taken back, and nothing settles.
    public func undoToast() {
        toastTask?.cancel()
        toastTask = nil
        let undo = toastUndo
        toastUndo = nil
        toastSettle = nil
        toast = nil
        undo?()
    }

    // MARK: What is reported

    /// Copies `text` and says so: "Summary copied".
    public func copy(_ text: String, as what: String) {
        TextInjector.copy(text)
        showToast(symbol: "checkmark.circle.fill", "\(what) copied")
    }

    /// Forgets a dictation, with Undo.
    public func removeDictationWithUndo(id: UUID) {
        let wasSelected = librarySelection == .dictation(id)
        guard let removed = removeDictation(id: id) else { return }
        showToast(symbol: "minus.circle.fill", "Dictation removed", undo: { [weak self] in
            guard let self else { return }
            self.restoreDictation(removed.entry, at: removed.index)
            if wasSelected { self.librarySelection = .dictation(id) }
        })
    }

    /// A meeting to the Trash, with Undo. Its voices are forgotten only
    /// once the toast has gone: until then the meeting can come back, and
    /// should come back whole.
    public func trashMeeting(at url: URL) {
        guard let library else { return }
        let record = library.record(at: url)
        let wasSelected = librarySelection == .meeting(url)
        cancelSummary(url)
        guard let trashed = try? library.trash(url) else {
            showToast(symbol: "exclamationmark.circle.fill", "Could not move to the Trash")
            return
        }
        if wasSelected { librarySelection = nil }
        let title = record?.title ?? url.deletingPathExtension().lastPathComponent
        showToast(symbol: "trash.circle.fill", "“\(title)” moved to Trash", undo: { [weak self] in
            guard let self else { return }
            library.restore(trashed)
            if wasSelected { self.librarySelection = .meeting(url) }
        }, settle: { [weak self] in
            if let record { self?.forgetVoices(of: record) }
        })
    }
}
