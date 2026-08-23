import AppKit
import Observation
import SwiftUI
import WhisperbarCore

/// Wires the hotkey, the recorder, the engine and the injector into the state
/// machine from §4, and owns the one piece of state every UI surface reads.
@MainActor
@Observable
public final class AppCoordinator {

    public private(set) var state: DictationState = .idle {
        didSet { overlay?.model.state = state }
    }
    /// 0…1, driven by the recorder at ~30 Hz. The overlay's waveform.
    public private(set) var inputLevel: Float = 0 {
        didSet { overlay?.model.level = inputLevel }
    }
    public private(set) var lastTranscript: String?
    /// Most recent first, capped. In memory only for now (§4, HistoryStore).
    public private(set) var history: [String] = []

    public let settingsStore: SettingsStore
    public let permissions: PermissionsCoordinator
    public let models: ModelManager

    private let hotkeys = HotkeyManager()
    private let recorder = AudioRecorder()
    private let engine: any TranscriptionEngine
    private var overlay: OverlayController?

    private var resetTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?

    private static let historyLimit = 20

    public init(settingsStore: SettingsStore = SettingsStore(),
                permissions: PermissionsCoordinator = PermissionsCoordinator(),
                models: ModelManager = ModelManager(),
                engine: any TranscriptionEngine = StubTranscriptionEngine()) {
        self.settingsStore = settingsStore
        self.permissions = permissions
        self.models = models
        self.engine = engine
    }

    /// The model transcription should use: whatever is selected, falling back
    /// to any installed model so a fresh install works before the user has
    /// picked one. Nil means nothing is installed yet.
    public var activeModel: InstalledModel? {
        models.installedModel(id: settingsStore.settings.activeModelID)
            ?? models.installed.first
    }

    // MARK: Lifecycle

    public func start() {
        try? AppPaths.ensureDirectories()

        overlay = OverlayController()

        recorder.onLevel = { [weak self] level in
            self?.inputLevel = level
        }
        recorder.onFailure = { [weak self] error in
            self?.fail(error.localizedDescription)
        }

        hotkeys.onEvent = { [weak self] event in
            switch event {
            case .begin: self?.beginRecording()
            case .end: self?.finishRecording()
            case .cancel: self?.cancel()
            }
        }

        permissions.onAccessibilityChange = { [weak self] trusted in
            guard let self else { return }
            if trusted { self.hotkeys.restart() } else { self.hotkeys.stop() }
        }
        permissions.beginPolling()

        applySettings()
        try? hotkeys.start()
    }

    public func shutDown() {
        maxDurationTask?.cancel()
        resetTask?.cancel()
        recorder.cancel()
        hotkeys.stop()
        permissions.stopPolling()
        settingsStore.flush()
    }

    /// Called when the hotkey or mode changes in Settings.
    public func applySettings() {
        let settings = settingsStore.settings
        hotkeys.hotkey = settings.hotkey
        hotkeys.mode = settings.hotkeyMode
    }

    public var isHotkeyRunning: Bool { hotkeys.isRunning }

    // MARK: The loop

    public func beginRecording() {
        guard !state.isBusy else { return }
        resetTask?.cancel()

        guard permissions.microphone.isGranted else {
            fail("Whisperbar needs microphone access.")
            return
        }

        let settings = settingsStore.settings
        do {
            try recorder.start(maxSeconds: settings.maxRecordingSeconds)
        } catch {
            fail(error.localizedDescription)
            return
        }

        state = .recording
        overlay?.show(position: settings.overlayPosition)

        // Warm the model while the user is still talking — cold load is what
        // dominates perceived latency (§5.4).
        Task { [engine, model = activeModel ?? Self.placeholderModel] in
            try? await engine.load(model: model)
        }

        // Runaway captures are capped rather than left to fill the buffer.
        maxDurationTask = Task { [weak self, max = settings.maxRecordingSeconds] in
            try? await Task.sleep(for: .seconds(max))
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
    }

    public func finishRecording() {
        guard state == .recording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let samples = recorder.stop()
        inputLevel = 0

        guard samples.count > Int(0.2 * AudioRecorder.sampleRate) else {
            fail("That was too short to transcribe.")
            return
        }

        state = .transcribing
        let settings = settingsStore.settings

        let model = activeModel ?? Self.placeholderModel
        Task { [weak self, engine] in
            do {
                let options = TranscribeOptions(
                    language: settings.language,
                    translateToEnglish: settings.translateToEnglish,
                    initialPrompt: TranscriptFormatter.initialPrompt(
                        from: settings.customVocabulary))
                try await engine.load(model: model)
                let transcript = try await engine.transcribe(samples: samples,
                                                             options: options)
                await self?.deliver(transcript)
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    private func deliver(_ transcript: Transcript) async {
        let settings = settingsStore.settings
        let text = TranscriptFormatter.format(transcript.text, settings: settings)

        guard !text.isEmpty else {
            fail("Nothing was transcribed.")
            return
        }

        state = .injecting
        lastTranscript = text
        history.insert(text, at: 0)
        if history.count > Self.historyLimit { history.removeLast() }

        let result = await TextInjector.inject(text,
                                               action: settings.outputAction,
                                               method: settings.injectionMethod)

        switch result {
        case .pasted, .typed:
            state = .finished(text)
        case .copiedOnly(let reason):
            // Not a failure — the text is on the clipboard either way, so say
            // what happened instead of pretending it pasted.
            state = reason.map { .failed($0) } ?? .finished(text)
        }

        scheduleReturnToIdle(after: .milliseconds(900))
    }

    public func cancel() {
        guard state.isCancellable else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        inputLevel = 0
        state = .idle
        overlay?.hide()
    }

    private func fail(_ message: String) {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        inputLevel = 0
        state = .failed(message)
        overlay?.show(position: settingsStore.settings.overlayPosition)
        scheduleReturnToIdle(after: .seconds(2.5))
    }

    private func scheduleReturnToIdle(after duration: Duration) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.state = .idle
            self?.overlay?.hide()
        }
    }

    // MARK: Menu bar actions

    public func copyLastTranscript() {
        guard let lastTranscript else { return }
        TextInjector.copy(lastTranscript)
    }

    /// Used only while the engine is the stub, which ignores it. Once
    /// WhisperKit lands, `activeModel` is the real answer and a nil there has
    /// to become a visible "no model installed" error rather than this.
    private static let placeholderModel = InstalledModel(
        id: "stub",
        displayName: "Stub engine",
        sizeBytes: 0,
        url: AppPaths.modelsDirectory)
}
