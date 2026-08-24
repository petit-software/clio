import AppKit
import Observation
import SwiftUI
import ClioCore

/// Wires the hotkey, the recorder, the engine and the injector into the state
/// machine from §4, and owns the one piece of state every UI surface reads.
@MainActor
@Observable
public final class AppCoordinator {

    public private(set) var state: DictationState = .idle {
        didSet { overlay?.update(state: state) }
    }
    /// 0…1, driven by the recorder at ~30 Hz. The overlay's waveform.
    public private(set) var inputLevel: Float = 0 {
        didSet { overlay?.model.level = inputLevel }
    }
    public private(set) var lastTranscript: String?

    public let settingsStore: SettingsStore
    public let permissions: PermissionsCoordinator
    public let models: ModelManager
    public let history: HistoryStore
    public let audioDevices: AudioDeviceMonitor
    /// Nil in previews and tests: starting a real updater would schedule
    /// network checks from a preview canvas.
    public let updates: UpdateManager?

    private let hotkeys = HotkeyManager()
    private let recorder = AudioRecorder()
    private let feedback = FeedbackPlayer()
    private let engine: any TranscriptionEngine
    private var overlay: OverlayController?

    private var resetTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    /// Bumped whenever a session ends, so work started by an earlier one can
    /// tell that it is stale.
    ///
    /// Task cancellation alone is not enough: `transcribe` runs a CoreML
    /// inference that does not check for cancellation partway through, so a
    /// cancelled task still returns a transcript. Without this token that
    /// transcript would be pasted into the user's document after they had
    /// already pressed Esc.
    private var sessionToken = 0

    public init(settingsStore: SettingsStore = SettingsStore(),
                permissions: PermissionsCoordinator = PermissionsCoordinator(),
                models: ModelManager = ModelManager(),
                audioDevices: AudioDeviceMonitor = AudioDeviceMonitor(),
                history: HistoryStore? = nil,
                updates: UpdateManager? = nil,
                engine: any TranscriptionEngine = WhisperKitEngine()) {
        self.settingsStore = settingsStore
        self.permissions = permissions
        self.models = models
        self.audioDevices = audioDevices
        self.updates = updates
        self.history = history
            ?? HistoryStore(persistsToDisk: settingsStore.settings.keepHistoryOnDisk)
        self.engine = engine
    }

    /// The model transcription will use. Nil means nothing is installed.
    public var activeModel: InstalledModel? {
        models.installedModel(id: settingsStore.settings.activeModelID)
            ?? models.installed.first
    }

    /// Keep the stored selection pointing at a model that is actually there.
    ///
    /// `activeModel` already falls back to the first installed model, so
    /// dictation worked with no selection stored — but Settings read the
    /// stored value and showed nothing selected, which said the app was
    /// broken when it was not. This writes the fallback down so the two agree.
    ///
    /// It also covers the selection going stale on its own: the active model
    /// being deleted, or the bundle identifier changing and moving Application
    /// Support out from under a stored id.
    public func reconcileActiveModel() {
        let stored = settingsStore.settings.activeModelID
        if let stored, models.isInstalled(stored) { return }

        let replacement = models.installed.first?.id
        guard replacement != stored else { return }
        settingsStore.settings.activeModelID = replacement
    }

    // MARK: Lifecycle

    public func start() {
        try? AppPaths.ensureDirectories()

        overlay = OverlayController()
        // Clicking the pill while it is transcribing abandons the run.
        overlay?.onCancel = { [weak self] in self?.cancel() }

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

        // A download finishing or a deletion can invalidate the stored choice.
        models.onInstalledChanged = { [weak self] in self?.reconcileActiveModel() }
        reconcileActiveModel()

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
        history.persistsToDisk = settings.keepHistoryOnDisk
    }

    public var isHotkeyRunning: Bool { hotkeys.isRunning }

    // MARK: The loop

    public func beginRecording() {
        guard !state.isBusy else { return }
        resetTask?.cancel()

        guard permissions.microphone.isGranted else {
            fail("Clio needs microphone access.")
            return
        }

        let settings = settingsStore.settings
        do {
            try recorder.start(maxSeconds: settings.maxRecordingSeconds,
                               deviceUID: settings.inputDeviceUID)
        } catch {
            fail(error.localizedDescription)
            return
        }

        state = .recording
        overlay?.show(position: settings.overlayPosition)
        feedback.play(.start, enabled: settings.playSoundOnStart)

        // Warm the model while the user is still talking — cold load is what
        // dominates perceived latency (§5.4). Failures are swallowed here on
        // purpose; finishRecording loads again and reports properly.
        if let model = activeModel {
            Task { [engine] in try? await engine.load(model: model) }
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

        let captured = recorder.stop()
        inputLevel = 0

        guard captured.count > Int(0.2 * AudioRecorder.sampleRate) else {
            fail("That was too short to transcribe.")
            return
        }

        guard let model = activeModel else {
            fail("No model installed — open Settings ▸ Model to download one.")
            return
        }

        let settings = settingsStore.settings
        feedback.play(.stop, enabled: settings.playSoundOnStop)

        // Trim silence before handing it over. Whisper pads to a 30s window
        // internally, so this is the cheapest latency win there is (§5.3).
        var samples = captured
        if settings.voiceActivityDetection {
            guard let trimmed = VoiceActivityTrimmer.trim(
                captured, sensitivity: settings.vadSensitivity) else {
                fail("No speech detected.")
                return
            }
            samples = trimmed.samples
        }

        state = .transcribing
        let token = sessionToken

        transcriptionTask = Task { [weak self, engine] in
            do {
                let options = TranscribeOptions(
                    language: settings.language,
                    translateToEnglish: settings.translateToEnglish,
                    initialPrompt: TranscriptFormatter.initialPrompt(
                        from: settings.customVocabulary))
                try await engine.load(model: model)
                let transcript = try await engine.transcribe(samples: samples,
                                                             options: options)
                guard !Task.isCancelled else { return }
                await self?.deliver(transcript, token: token)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.sessionToken == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func deliver(_ transcript: Transcript, token: Int) async {
        // The user cancelled while this was running. Delivering now would
        // paste text into whatever they moved on to.
        guard sessionToken == token else { return }

        let settings = settingsStore.settings
        let text = TranscriptFormatter.format(transcript.text, settings: settings)

        guard !text.isEmpty else {
            fail("Nothing was transcribed.")
            return
        }

        state = .injecting
        lastTranscript = text
        history.add(text)

        let result = await TextInjector.inject(text,
                                               action: settings.outputAction,
                                               method: settings.injectionMethod)

        guard sessionToken == token else { return }

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
        // Invalidate first: anything in flight checks this before it lands.
        sessionToken &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        inputLevel = 0
        state = .idle
        overlay?.hide()
        feedback.play(.cancel, enabled: settingsStore.settings.playSoundOnCancel)
    }

    private func fail(_ message: String) {
        sessionToken &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        inputLevel = 0
        state = .failed(message)
        overlay?.show(position: settingsStore.settings.overlayPosition)
        feedback.play(.cancel, enabled: settingsStore.settings.playSoundOnCancel)
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

    public func copy(_ entry: TranscriptEntry) {
        TextInjector.copy(entry.text)
    }

    // MARK: Microphone

    /// Nil means "follow the system default".
    public func selectInputDevice(uid: String?) {
        settingsStore.settings.inputDeviceUID = uid
    }

    public var selectedInputUID: String? {
        settingsStore.settings.inputDeviceUID
    }

    /// The microphone the next recording will actually use.
    public var effectiveInputDevice: AudioInputDevice? {
        audioDevices.resolved(uid: selectedInputUID)
    }

    /// The user picked a microphone that is not plugged in. We will fall back
    /// to the default, but the menu should say so rather than let them think
    /// they are recording from something they are not.
    public var selectedInputIsMissing: Bool {
        audioDevices.isMissing(uid: selectedInputUID)
    }

}
