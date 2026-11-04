import Foundation
import ClioCore

/// Which model writes meeting summaries, and writing one again.
extension AppCoordinator {

    /// The model Settings points at: a downloaded one, if chosen and still
    /// installed, else Apple's, if this Mac has it. Nil when nothing can
    /// write a summary.
    public var summaryModel: (any SummaryLanguageModel)? {
        if let installed = chosenLocalSummaryModel {
            return localSummaryModel(for: installed)
        }
        return MeetingSummarizer.system
    }

    /// For the window: "Apple Intelligence", or the downloaded model's name.
    public var summaryModelName: String {
        chosenLocalSummaryModel?.displayName ?? "Apple Intelligence"
    }

    /// Whether a summary can be written right now.
    public var canSummarize: Bool {
        chosenLocalSummaryModel != nil || MeetingSummarizer.isAvailable
    }

    /// The downloaded model Settings has chosen, when it is on disk.
    var chosenLocalSummaryModel: InstalledModel? {
        guard let id = settingsStore.settings.summaryModelID,
              let installed = models.installedModel(id: id),
              installed.kind == .language, installed.weightsFile != nil else { return nil }
        return installed
    }

    /// One runtime per weights file, kept so a run of summaries loads the
    /// weights once. Choosing another model lets go of the one before: two
    /// of them loaded is more memory than most Macs have for it.
    func localSummaryModel(for installed: InstalledModel) -> LocalSummaryModel {
        let file = installed.weightsFile!
        if let model = localSummaryModels[file] { return model }
        for (other, model) in localSummaryModels where other != file {
            Task { await model.unload() }
        }
        localSummaryModels = [:]
        let model = LocalSummaryModel(file: file, name: installed.displayName,
                                      idleTime: summaryModelIdleTime)
        localSummaryModels[file] = model
        return model
    }

    /// Keeps the chosen summary model pointing at one that exists — the
    /// stored id outlives a deleted download — and picks up a language model
    /// the moment its download finishes: whoever downloaded it wants it.
    func reconcileSummaryModel() {
        let installed = Set(models.installed(.language).map(\.id))
        if let id = settingsStore.settings.summaryModelID, !installed.contains(id) {
            settingsStore.settings.summaryModelID = nil
        }
        if let known = knownLanguageModelIDs,
           let arrived = installed.subtracting(known).sorted().first,
           models.installedModel(id: arrived).map(models.canDelete) == true {
            settingsStore.settings.summaryModelID = arrived
        }
        knownLanguageModelIDs = installed
    }

    // MARK: Writing one again

    public func isSummarizing(_ url: URL) -> Bool { summarizingFiles.contains(url) }

    /// Writes the summary of a saved meeting again, with the model Settings
    /// names now, and puts it in the file. The old summary stays until the
    /// new one is in, so a model that fails costs nothing.
    public func resummarize(_ url: URL) {
        guard summaryTasks[url] == nil else { return }
        guard let model = summaryModel else {
            summaryProblem = "No model can write a summary. Choose one in Settings ▸ Model."
            return
        }
        guard let library, let record = library.record(at: url) else { return }
        guard !record.lines.isEmpty else {
            summaryProblem = "Nothing was transcribed, so there is nothing to summarize."
            return
        }
        if let meeting, meeting.isActive, meeting.fileURL == url { return }

        summaryProblem = nil
        summarizingFiles.insert(url)
        let name = summaryModelName
        summaryTasks[url] = Task { @MainActor [weak self] in
            let summary = await MeetingSummarizer.summarize(record, with: model)
            guard let self else { return }
            defer {
                summaryTasks[url] = nil
                summarizingFiles.remove(url)
            }
            guard !Task.isCancelled else { return }
            guard let summary else {
                summaryProblem = "\(name) could not write a summary of this meeting."
                return
            }
            // Into the file as it is now, not as it was read: the notes may
            // have been edited meanwhile.
            guard var current = library.record(at: url) else { return }
            current.summary = summary
            do {
                try library.save(current, at: url)
            } catch {
                summaryProblem = error.localizedDescription
            }
        }
    }

    /// Summarize Again, from the bundle, on one meeting file — the same path
    /// the ⋯ menu takes, with the model Settings names — and the summary
    /// printed. Writes into that file, as the menu would.
    ///
    ///     CLIO_SUMMARIZE="$HOME/Documents/Clio Meetings/<file>.md" Clio.app/Contents/MacOS/Clio
    public func runSummaryCheck(file: URL) async -> String {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return "[summarize] FAILED: no file at \(file.path)"
        }
        if library == nil { library = MeetingLibrary(folder: file.deletingLastPathComponent()) }
        let before = library?.record(at: file)?.summary
        let began = Date()
        resummarize(file)
        guard isSummarizing(file) else {
            return "[summarize] FAILED: \(summaryProblem ?? "did not start")"
        }
        while isSummarizing(file) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(began))
        guard let after = library?.record(at: file)?.summary else {
            return "[summarize] FAILED after \(elapsed) s: \(summaryProblem ?? "no summary in the file")"
        }
        let changed = after != before
        return """
            [summarize] by \(summaryModelName) in \(elapsed) s, \
            \(before == nil ? "new" : changed ? "replaced the old one" : "identical to the old one")
            [summarize] file: \(file.path)
            \(after)
            """
    }

    /// Stops a summary being written for `url` — the meeting was trashed.
    public func cancelSummary(_ url: URL) {
        summaryTasks[url]?.cancel()
        summaryTasks[url] = nil
        summarizingFiles.remove(url)
    }
}
