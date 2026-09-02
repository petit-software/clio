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
        didSet { overlay?.update(state: state, note: limitNote) }
    }
    /// 0…1, driven by the recorder at ~30 Hz. The overlay's waveform.
    public private(set) var inputLevel: Float = 0 {
        didSet { overlay?.model.level = inputLevel }
    }
    public private(set) var lastTranscript: String?

    /// True once the microphone is actually running. The pill is up before
    /// this, so it can say it is waking rather than pretend to hear.
    public private(set) var captureIsLive = false {
        didSet { overlay?.model.captureIsLive = captureIsLive }
    }

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

    /// Set when the maximum-duration cap ended the recording rather than the
    /// user releasing the key.
    private var stoppedAtLimit = false

    /// Starting the audio hardware takes about half a second and used to run
    /// on the main actor, so the pill could not paint until it finished. It
    /// runs off it now, and this is how the rest of the flow waits for it.
    private var captureStart: Task<Bool, Never>?
    private var limitNote: String?

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
            guard let self else { return }
            self.inputLevel = level
            self.overlay?.updateProgress(
                elapsed: self.recorder.duration,
                limit: self.settingsStore.settings.maxRecordingSeconds)
        }
        recorder.onFailure = { [weak self] error in
            self?.fail(error.localizedDescription)
        }

        // So Esc abandons a dictation started from the menu too, not only one
        // the shortcut began.
        hotkeys.isSessionActive = { [weak self] in
            self?.state.isCancellable ?? false
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
        hotkeys.secondaryHotkey = settings.secondaryHotkey
        hotkeys.mode = settings.hotkeyMode
        history.persistsToDisk = settings.keepHistoryOnDisk
        overlay?.model.surface = PillSurface(opacity: settings.pillOpacity,
                                             isClear: settings.pillClearGlass)
    }

    public var isHotkeyRunning: Bool { hotkeys.isRunning }

    // MARK: The loop

    public func beginRecording() {
        guard !state.isBusy else { return }
        resetTask?.cancel()
        stoppedAtLimit = false
        limitNote = nil

        guard permissions.microphone.isGranted else {
            fail("Clio needs microphone access.")
            return
        }

        let settings = settingsStore.settings

        // The pill goes up FIRST, before anything slow happens. Starting the
        // input device costs ~425ms and used to run right here on the main
        // actor, which meant the window could not even paint until it was
        // done — the feedback arrived two thirds of a second after the key.
        state = .recording
        overlay?.model.surface = PillSurface(opacity: settings.pillOpacity,
                                             isClear: settings.pillClearGlass)
        overlay?.show(position: settings.overlayPosition)
        feedback.play(.start, enabled: settings.playSoundOnStart)

        // Capture starts off the main actor. The pill shows that it is still
        // waking up until this lands, so it never claims to be listening
        // before it is.
        captureIsLive = false
        let recorder = self.recorder
        captureStart = Task.detached(priority: .userInitiated) {
            do {
                try recorder.start(maxSeconds: settings.maxRecordingSeconds,
                                   deviceUID: settings.inputDeviceUID)
                return true
            } catch is CancellationError {
                // Esc landed while the microphone was still waking up. The
                // session is already over; nothing to report.
                return false
            } catch {
                await MainActor.run { [weak self] in
                    self?.fail(error.localizedDescription)
                }
                return false
            }
        }
        Task { [weak self] in
            guard await self?.captureStart?.value == true else { return }
            guard let self, self.state == .recording else { return }
            self.captureIsLive = true
        }

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
            // Cutting someone off is defensible; doing it without a word is
            // not. The transcript still arrives — it just says why it ends
            // where it does.
            self?.stoppedAtLimit = true
            self?.finishRecording()
        }
    }

    public func finishRecording() {
        guard state == .recording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        // Released before the hardware finished waking. Stopping now would
        // find an engine that is still starting and throw the words away.
        guard captureStart == nil || captureIsLive else {
            Task { [weak self] in
                _ = await self?.captureStart?.value
                self?.finishRecording()
            }
            return
        }
        captureStart = nil

        let captured = recorder.stop()
        inputLevel = 0

        guard captured.count > Int(0.2 * AudioRecorder.sampleRate) else {
            nothingHeard("That was too short to transcribe.")
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
                nothingHeard("No speech detected.")
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
            nothingHeard("Nothing was transcribed.")
            return
        }

        state = .injecting
        lastTranscript = text
        history.add(text)

        limitNote = stoppedAtLimit
            ? RecordingProgress.limitDescription(seconds: settings.maxRecordingSeconds)
            : nil

        let result = await TextInjector.inject(
            text,
            action: settings.outputAction,
            method: settings.injectionMethod,
            keepOnClipboard: settings.keepTranscriptOnClipboard)

        guard sessionToken == token else { return }

        // What the pill claims afterwards has to match where the words
        // actually are: copy-only always leaves them there, pasting only when
        // the user asked it to keep them.
        overlay?.model.transcriptIsOnClipboard =
            settings.outputAction == .copyOnly || settings.keepTranscriptOnClipboard

        switch result {
        case .pasted, .typed:
            state = .finished(text)
        case .copiedOnly(let reason):
            // Not a failure — the text is on the clipboard either way, so say
            // what happened instead of pretending it pasted.
            overlay?.model.transcriptIsOnClipboard = true
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
        captureStart?.cancel()
        captureStart = nil
        captureIsLive = false
        recorder.cancel()
        inputLevel = 0
        limitNote = nil
        state = .idle
        overlay?.hide()
        feedback.play(.cancel, enabled: settingsStore.settings.playSoundOnCancel)
    }

    /// The dictation produced no words. Said the same way as a failure in the
    /// overlay, because the user still needs to know why nothing appeared —
    /// but without the menu bar warning, since nothing is broken.
    private func nothingHeard(_ message: String) {
        endSession(with: .emptyResult(message))
    }

    private func fail(_ message: String) {
        endSession(with: .failed(message))
    }

    private func endSession(with outcome: DictationState) {
        sessionToken &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        inputLevel = 0
        state = outcome
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

    /// Flash the pill where the chosen position puts it.
    ///
    /// Refused outright while a dictation is running: the pill is showing
    /// something real, and moving it mid-sentence to demonstrate a setting
    /// would be worse than not demonstrating it.
    public func previewOverlayPosition(_ position: OverlayPosition) {
        guard !state.isBusy else { return }
        let settings = settingsStore.settings
        overlay?.showPreview(
            at: position,
            surface: PillSurface(opacity: settings.pillOpacity,
                                 isClear: settings.pillClearGlass))
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
