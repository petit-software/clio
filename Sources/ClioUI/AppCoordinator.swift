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
        didSet {
            overlay?.update(state: state, note: limitNote)
            // A dictation takes the microphone from the level in Settings,
            // and gives it back.
            updateLevelMonitor()
            // Words dictated into a text field during a call are not part
            // of the meeting.
            meeting?.isMicrophoneSuppressed = state == .recording
        }
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
    public let calendar: MeetingCalendar

    /// The meeting being recorded, or the last one, until another starts.
    public internal(set) var meeting: MeetingSession?
    /// Why the last attempt to start a meeting did not, for the menu.
    public internal(set) var meetingProblem: String?
    /// Every meeting in the notes folder. Made when the library window
    /// first opens: reading the folder is not something launch should wait on.
    public internal(set) var library: MeetingLibrary?
    var libraryWindow: LibraryWindowController?
    /// What the library window is showing.
    public var librarySelection: LibrarySelection?
    /// The day the library's sidebar shows.
    public var libraryDay = Calendar.current.startOfDay(for: Date())
    #if DEBUG
    /// Dictations for the CLIO_LIBRARY_SHOW tool, which must not write
    /// samples into the real history.
    var libraryDictationsOverride: [TranscriptEntry]?
    /// Events for the CLIO_LIBRARY_SHOW tool, which has no calendar of its own.
    var libraryEventsOverride: [MeetingEvent]?
    #endif
    /// Set from the moment a meeting is asked for until it exists. The
    /// calendar prompt sits between the two, and a second start in that gap
    /// — the menu again, the call offer — made a second session, the first
    /// left recording with nothing able to stop it.
    var isStartingMeeting = false
    /// The call the meeting belongs to, so it can stop when the call does.
    var meetingCallApp: CallApp?
    var callWatch = CallWatch()
    var callWatchTask: Task<Void, Never>?
    var meetingOffer: MeetingOfferController?
    /// Meetings whose summary is being written again, by file, for the
    /// library to show it happening.
    public internal(set) var summarizingFiles: Set<URL> = []
    /// Why the last summary asked for was not written. Nil once one is.
    public internal(set) var summaryProblem: String?
    var summaryTasks: [URL: Task<Void, Never>] = [:]
    /// The downloaded summary models that have been used, by weights file,
    /// so a run of summaries loads the weights once — see
    /// `LocalSummaryModel.idleTime`.
    var localSummaryModels: [URL: LocalSummaryModel] = [:]
    /// The language models installed at the last look, to notice one arrive.
    var knownLanguageModelIDs: Set<String>?
    /// Nil in previews and tests: starting a real updater would schedule
    /// network checks from a preview canvas.
    public let updates: UpdateManager?

    private let hotkeys = HotkeyManager()
    private let recorder = AudioRecorder()
    /// Nil in previews and tests, which must not open a microphone.
    private let levelMonitor: InputLevelMonitor?
    private let feedback = FeedbackPlayer()
    /// The engine, shared with meetings one job at a time — dictation first.
    let engine: TranscriptionQueue
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
                levelMonitor: InputLevelMonitor? = InputLevelMonitor(),
                calendar: MeetingCalendar? = nil,
                engine: any TranscriptionEngine = WhisperKitEngine()) {
        self.settingsStore = settingsStore
        self.permissions = permissions
        self.models = models
        self.audioDevices = audioDevices
        self.calendar = calendar ?? MeetingCalendar()
        self.updates = updates
        self.levelMonitor = levelMonitor
        self.history = history
            ?? HistoryStore(persistsToDisk: settingsStore.settings.keepHistoryOnDisk)
        self.engine = TranscriptionQueue(engine)
    }

    /// The model transcription will use. Nil means nothing is installed.
    /// Speech models only: the folder also holds summary models, and a GGUF
    /// handed to WhisperKit is a dictation that fails.
    public var activeModel: InstalledModel? {
        let stored = models.installedModel(id: settingsStore.settings.activeModelID)
        return stored?.kind == .speech ? stored : models.installed(.speech).first
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
        reconcileSummaryModel()
        let stored = settingsStore.settings.activeModelID
        if let stored, models.installedModel(id: stored)?.kind == .speech { return }

        let replacement = models.installed(.speech).first?.id
        guard replacement != stored else { return }
        settingsStore.settings.activeModelID = replacement
    }

    // MARK: Lifecycle

    public func start() {
        try? AppPaths.ensureDirectories()
        watchForCalls()

        overlay = OverlayController()
        // Clicking the pill while it is transcribing abandons the run.
        overlay?.onCancel = { [weak self] in self?.cancel() }
        overlay?.microphoneMenu = { [weak self] in self?.microphoneMenu?() }

        recorder.onBands = { [weak self] bands in
            self?.overlay?.model.bands = bands
        }
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

        levelMonitor?.onLevel = { [weak self] level in
            guard let self else { return }
            // Up at once, down over half a second: a bar that falls as fast
            // as it rises flickers between words.
            self.monitoredLevel = max(level, self.monitoredLevel - 0.06)
        }
        // A headset connecting moves the system default, and the level has
        // to move with it — or stop, if the new one is not opened unasked.
        audioDevices.onChange = { [weak self] in self?.updateLevelMonitor() }
        levelMonitor?.onStatus = { [weak self] status in
            self?.levelMonitorStatus = status
            if status != .listening { self?.monitoredLevel = 0 }
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
            // Re-granting Accessibility must not switch a paused Clio back on.
            if trusted, self.isListening { self.hotkeys.restart() } else { self.hotkeys.stop() }
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
        levelMonitor?.stop()
        hotkeys.stop()
        permissions.stopPolling()
        // Quitting mid-meeting keeps what was transcribed; the chunks still
        // in flight are lost, which beats holding the quit up for them.
        callWatchTask?.cancel()
        meeting?.abandon()
        settingsStore.flush()
    }

    /// Called when the hotkey or mode changes in Settings.
    public func applySettings() {
        let settings = settingsStore.settings
        hotkeys.hotkey = settings.hotkey
        hotkeys.secondaryHotkey = settings.secondaryHotkey
        hotkeys.mode = settings.hotkeyMode
        history.persistsToDisk = settings.keepHistoryOnDisk
        overlay?.apply(surface: Self.pillSurface(settings), size: settings.pillSize)
    }

    /// The pill's look is fixed — see PillSurface — so this is the same
    /// whatever the settings say. Kept as the one place it is asked for.
    private static func pillSurface(_ settings: ClioCore.Settings) -> PillSurface {
        PillSurface()
    }

    public var isHotkeyRunning: Bool { hotkeys.isRunning }

    /// The switch in the menu. Off, and the shortcut is not listened for:
    /// the tap comes down, so the keys go to whatever app has them, and the
    /// menu bar mark dims. Anything in flight is abandoned first, so the
    /// switch cannot leave a recording running with no way to stop it.
    /// Not persisted — a relaunch listens, which is what a fresh start of a
    /// dictation app should do.
    public var isListening = true {
        didSet {
            guard isListening != oldValue else { return }
            if isListening {
                try? hotkeys.start()
            } else {
                cancel()
                hotkeys.stop()
            }
        }
    }

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
        overlay?.apply(surface: Self.pillSurface(settings), size: settings.pillSize)
        overlay?.show(position: settings.overlayPosition)
        feedback.play(.start, enabled: settings.playSoundOnStart)

        // Capture starts off the main actor. The pill shows that it is still
        // waking up until this lands, so it never claims to be listening
        // before it is.
        captureIsLive = false
        let recorder = self.recorder
        let levelMonitor = self.levelMonitor
        captureStart = Task.detached(priority: .userInitiated) {
            do {
                // If Settings was showing the level, it has been told to
                // stop — setting the state above did that — and this waits
                // for it to have let go. Nothing to wait for otherwise.
                levelMonitor?.waitUntilSettled()
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
            nothingHeard("Too short.")
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
                let transcript = try await engine.transcribe(samples: samples,
                                                             options: options,
                                                             model: model,
                                                             priority: .dictation)
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

        // A little over the old 900: the pill lets its activity ring go
        // out before it draws the result, and the hold is counted from here.
        scheduleReturnToIdle(after: .milliseconds(1100))
        releaseModelsIfNotKept()
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
        releaseModelsIfNotKept()
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
        releaseModelsIfNotKept()
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
        overlay?.showPreview(at: position,
                             surface: Self.pillSurface(settings),
                             size: settings.pillSize)
    }

    // MARK: Microphone

    /// Nil means "follow the system default".
    public func selectInputDevice(uid: String?) {
        guard uid != settingsStore.settings.inputDeviceUID else { return }
        settingsStore.settings.inputDeviceUID = uid
        // Permission to listen was for the microphone that was showing.
        levelWasAskedFor = false
        updateLevelMonitor()
        // Chosen mid-dictation — from the pill, usually — so the words
        // still to come are from the microphone just picked. Off the main
        // actor: opening a device takes up to half a second, longer for a
        // headset, and the pill must keep drawing meanwhile.
        if state == .recording {
            let recorder = recorder
            Task.detached { recorder.switchDevice(uid: uid) }
        }
    }

    /// The microphone menu, as the menu bar draws it. Set by whoever owns
    /// the menu bar, so the pill offers the very same list.
    public var microphoneMenu: (() -> NSMenu)?

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

    // MARK: Microphone level in Settings

    /// 0…1 from the microphone while Settings is showing it and no dictation
    /// is running.
    public private(set) var monitoredLevel: Float = 0
    public private(set) var levelMonitorStatus: InputLevelMonitor.Status = .off

    /// What the bar in Settings draws: the dictation's own level while there
    /// is one, since it has the microphone, and the monitor's otherwise.
    public var displayedInputLevel: Float {
        state == .recording ? inputLevel : monitoredLevel
    }

    private var levelIsOnShow = false
    private var levelWasAskedFor = false

    /// True when showing a level would mean opening a microphone its owner
    /// notices — a Bluetooth headset drops into call mode, an iPhone connects
    /// — so Settings offers a button instead of simply listening.
    public var inputLevelNeedsAsking: Bool {
        guard let device = effectiveInputDevice else { return false }
        return !device.transport.opensQuietly && !levelWasAskedFor
    }

    /// The pane with the level bar came on screen, or left it.
    public func setInputLevelOnShow(_ onShow: Bool) {
        guard onShow != levelIsOnShow else { return }
        levelIsOnShow = onShow
        // Asked for once per look, not once for ever.
        if !onShow { levelWasAskedFor = false }
        updateLevelMonitor()
    }

    /// The button Settings shows in place of the bar for a microphone that
    /// does not open quietly.
    public func askForInputLevel() {
        levelWasAskedFor = true
        updateLevelMonitor()
    }

    private func updateLevelMonitor() {
        guard let levelMonitor else { return }
        let device = effectiveInputDevice
        let mayListen = device.map { $0.transport.opensQuietly || levelWasAskedFor } ?? false
        if let device, levelIsOnShow, mayListen, state != .recording,
           permissions.microphone.isGranted {
            // By name even when following the system default, so that the
            // default moving to another microphone is a change of target.
            levelMonitor.listen(to: device.id)
        } else {
            levelMonitor.stop()
        }
    }

}
