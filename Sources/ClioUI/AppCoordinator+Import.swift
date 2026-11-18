import AppKit
import ClioCore
import UniformTypeIdentifiers

/// A recording being imported: which, and what is being done with it.
public struct ImportStatus: Equatable, Sendable {
    public var name: String
    /// How much of the file has been transcribed, 0…1.
    public var fraction: Double
    /// What comes after the transcript, while it is happening.
    public var step: String?

    /// "Importing “Board call” · 42%"
    public var line: String {
        "Importing “\(name)” · " + (step ?? "\(Int(fraction * 100))%")
    }
}

/// A recording made elsewhere, brought in as a meeting.
extension AppCoordinator {

    /// The audio and video formats macOS decodes, for the panel and a drop.
    public static let importableTypes: [UTType] = [.audio, .movie]

    public func chooseRecordingToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.importableTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording. Clio transcribes it and adds it to your meetings."
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRecording(url)
    }

    public func cancelImport() {
        importTask?.cancel()
    }

    /// Turns the recording at `file` into a meeting in the library, and
    /// shows it when it is done. One at a time, and not during a meeting:
    /// both would be feeding the one speech model.
    public func importRecording(_ file: URL) {
        guard importTask == nil else {
            meetingProblem = "One recording is being imported already."
            return
        }
        if let meeting, meeting.isActive {
            meetingProblem = "Import the recording once the meeting has ended."
            return
        }
        guard let model = activeModel else {
            meetingProblem = "No model is installed. Download one in Settings ▸ Model."
            return
        }
        meetingProblem = nil
        let settings = settingsStore.settings
        let name = file.deletingPathExtension().lastPathComponent
        importStatus = ImportStatus(name: name, fraction: 0)

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                importTask = nil
                importStatus = nil
                releaseModelsIfNotKept()
            }
            var imported: MeetingSession?
            // What the session is doing once the file has been read through.
            let watcher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, let session = imported ?? self.importingSession else { continue }
                    switch session.phase {
                    case .identifying: self.importStatus?.step = "working out who spoke"
                    case .summarizing: self.importStatus?.step = "writing the summary"
                    default: break
                    }
                }
            }
            defer { watcher.cancel() }
            do {
                let session = try await MeetingImport.run(
                    file: file,
                    folder: MeetingMarkdown.folder(customPath: settings.meetingsFolderPath),
                    queue: engine, model: model,
                    options: TranscribeOptions(
                        language: settings.language, translateToEnglish: false,
                        initialPrompt: TranscriptFormatter.initialPrompt(from: settings.customVocabulary)),
                    sensitivity: settings.vadSensitivity,
                    configure: { [weak self] session in
                        self?.equip(session)
                        self?.importingSession = session
                    },
                    progress: { [weak self] fraction in
                        self?.importStatus?.fraction = fraction
                    })
                imported = session
                importingSession = nil
                if session.record.lines.isEmpty {
                    meetingProblem = "Nothing was said in “\(name)” that could be transcribed."
                }
                library?.reload()
                if let url = session.fileURL { showLibrary(selecting: .meeting(url)) }
            } catch is CancellationError {
                // Stopped: what was transcribed so far stays, as a meeting.
                if let session = importingSession { await session.stop(summarizing: false) }
                importingSession = nil
                library?.reload()
            } catch {
                importingSession = nil
                meetingProblem = error.localizedDescription
            }
        }
    }
}
