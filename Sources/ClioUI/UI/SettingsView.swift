import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import ClioCore

/// The tabs from §6. Model and Audio-device pickers are intentionally thin
/// here — ModelManager is Milestone 4 — but every control that Milestone 0 can
/// honestly back is wired to the store.
public struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    public var body: some View {
        TabView {
            GeneralTab(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab(coordinator: coordinator)
                .tabItem { Label("Model", systemImage: "cpu") }
            AudioTab(coordinator: coordinator)
                .tabItem { Label("Audio", systemImage: "mic") }
            TranscriptionTab(coordinator: coordinator)
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
            OutputTab(coordinator: coordinator)
                .tabItem { Label("Output", systemImage: "character.text.justify") }
            FeedbackTab(coordinator: coordinator)
                .tabItem { Label("Feedback", systemImage: "bell") }
            AboutTab(coordinator: coordinator)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 400)
        .floatingWindow()
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HotkeyRecorder(
                        coordinator: coordinator,
                        hotkey: Binding(
                            get: { coordinator.settingsStore.settings.hotkey },
                            set: { coordinator.settingsStore.settings.hotkey = $0 ?? .defaultHotkey }),
                        other: coordinator.settingsStore.settings.secondaryHotkey,
                        fallback: .defaultHotkey)
                }

                // Both chords are live at once. This one is here because fn
                // is the obvious dictation key on an Apple keyboard and does
                // not exist on anyone else's.
                LabeledContent("Alternate shortcut") {
                    HotkeyRecorder(
                        coordinator: coordinator,
                        hotkey: Binding(
                            get: { coordinator.settingsStore.settings.secondaryHotkey },
                            set: { coordinator.settingsStore.settings.secondaryHotkey = $0 }),
                        other: coordinator.settingsStore.settings.hotkey)
                }

                Picker("Mode", selection: Binding(
                    get: { coordinator.settingsStore.settings.hotkeyMode },
                    set: {
                        coordinator.settingsStore.settings.hotkeyMode = $0
                        coordinator.applySettings()
                    })) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                if let warning = keyboardWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Either shortcut starts a dictation. Set an alternate for "
                     + "a keyboard that lacks the key the first one uses.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Reads the login item itself, not the stored flag. The two
                // drift: the registration is per bundle identifier, so a rename
                // strands it, and the user then sees a switch that is on while
                // nothing launches. A control that lies about the system is
                // worse than one that is simply off.
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { setLaunchAtLogin($0) }))

                Toggle("Show icon in menu bar", isOn: Binding(
                    get: { coordinator.settingsStore.settings.showMenuBarIcon },
                    set: { coordinator.settingsStore.settings.showMenuBarIcon = $0 }))
            }

            Section {
                PermissionBanner(coordinator: coordinator)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Clio needs the microphone to hear you, and Accessibility "
                     + "to see its shortcut and paste into the app you are "
                     + "typing in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// `fn` only reports on Apple keyboards. Said once, and not at all when
    /// an alternate covers the other kind.
    private var keyboardWarning: String? {
        let settings = coordinator.settingsStore.settings
        let needsApple = settings.hotkeys.map(\.requiresAppleKeyboard)
        guard needsApple.contains(true) else { return nil }
        if needsApple.allSatisfy({ $0 }) {
            return settings.secondaryHotkey == nil
                ? "The fn (Globe) key only reports on Apple keyboards. "
                    + "Add an alternate shortcut for other keyboards."
                : "The fn (Globe) key only reports on Apple keyboards."
        }
        return nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The toggle reads the service, so a failure here needs no undo —
            // it will simply show what actually happened.
        }
        // Mirrored so the stored settings still describe the install.
        coordinator.settingsStore.settings.launchAtLogin =
            SMAppService.mainApp.status == .enabled
    }
}

/// Records the next chord the user presses.
///
/// A local NSEvent monitor is enough here — Settings is focused when it's in
/// use, so this does not need the global tap.
private struct HotkeyRecorder: View {
    @Bindable var coordinator: AppCoordinator
    @Binding var hotkey: Hotkey?
    /// The other shortcut, so the two are never recorded into a pair that
    /// cannot both fire.
    var other: Hotkey?
    /// What the ✕ puts back. Nil removes the shortcut outright; the primary
    /// passes the default, because there has to be some way in.
    var fallback: Hotkey?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflict: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Button(action: toggle) {
                    Text(label).frame(minWidth: 120)
                }
                if hotkey != nil, hotkey != fallback, !isRecording {
                    Button {
                        commit(fallback)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(fallback.map { "Reset to \($0.displayString)" }
                          ?? "Remove this shortcut")
                    .accessibilityLabel(fallback == nil ? "Remove shortcut"
                                                        : "Reset shortcut to default")
                }
            }
            if let conflict {
                Text(conflict)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press a shortcut…" }
        return hotkey?.displayString ?? "None"
    }

    private func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        conflict = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.type == .keyDown {
                guard event.keyCode != UInt16(kVK_Escape) else {
                    stopRecording()
                    return nil
                }
                record(Hotkey(keyCode: event.keyCode, modifierFlags: flags.rawValue))
                return nil
            }

            // Modifier-only chord: committed once the user has actually held
            // something, so a stray Shift while reaching for the key is not it.
            if !flags.isEmpty {
                record(Hotkey(keyCode: nil, modifierFlags: flags.rawValue))
            }
            return nil
        }
    }

    private func record(_ candidate: Hotkey) {
        if let other, let reason = Hotkey.conflict(between: candidate, and: other) {
            conflict = reason
            stopRecording()
            return
        }
        commit(candidate)
    }

    private func commit(_ hotkey: Hotkey?) {
        conflict = nil
        self.hotkey = hotkey
        coordinator.applySettings()
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Model

private struct ModelTab: View {
    @Bindable var coordinator: AppCoordinator
    @State private var deleteError: String?

    private var models: ModelManager { coordinator.models }

    var body: some View {
        Form {
            Section {
                ForEach(models.catalog) { model in
                    ModelRow(coordinator: coordinator,
                             model: model,
                             deleteError: $deleteError)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Models are downloaded once and run entirely on this Mac. "
                     + "Clio also finds models other tools have already "
                     + "downloaded to the shared Hugging Face cache.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let deleteError {
                Section {
                    Label(deleteError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section {
                Toggle("Keep model in memory", isOn: Binding(
                    get: { coordinator.settingsStore.settings.keepModelInMemory },
                    set: { coordinator.settingsStore.settings.keepModelInMemory = $0 }))
                Text("Cold-loading a large model costs several seconds. Keeping "
                     + "it resident trades memory for latency.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if models.installed.isEmpty {
                Section {
                    Label("Download a model to start dictating.",
                          systemImage: "arrow.down.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Folder") {
                    Text(AppPaths.modelsDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Reveal in Finder") {
                    try? AppPaths.ensureDirectories()
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: AppPaths.modelsDirectory.path)
                }
            } header: {
                Text("On disk")
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refreshInstalled() }
    }
}

private struct ModelRow: View {
    @Bindable var coordinator: AppCoordinator
    let model: CatalogModel
    @Binding var deleteError: String?

    private var models: ModelManager { coordinator.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // The active model is chosen by selecting an installed row,
                // rather than a separate picker that can point at nothing.
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .onTapGesture { if installed != nil { makeActive() } }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                controls
            }

            if let progress = models.downloads[model.id] {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progress.fraction)
                    Text(progressLabel(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let failure = models.failures[model.id] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    /// Symbols rather than words.
    ///
    /// Each row already carries a name, a size and a description, and three
    /// rows of it read as a wall. `help` keeps the meaning available to anyone
    /// who wants it, and to VoiceOver, which a bare glyph would otherwise
    /// leave with nothing to say.
    @ViewBuilder
    private var controls: some View {
        if models.isDownloading(model.id) {
            iconButton("xmark.circle.fill", "Cancel the download", .secondary) {
                models.cancel(model.id)
            }
        } else if let installed {
            if models.canDelete(installed) {
                iconButton("minus.circle.fill", "Delete \(model.displayName)", .secondary) {
                    delete(installed)
                }
            } else {
                // Not ours to delete, so there is no button to offer — see
                // ModelManager.canDelete.
                Image(systemName: "externaldrive")
                    .foregroundStyle(.tertiary)
                    .help("In the shared Hugging Face cache, so Clio will not delete it")
            }
        } else {
            iconButton("arrow.down.circle.fill", "Download \(model.displayName)", .accentColor) {
                models.download(model)
            }
        }
    }

    private func iconButton(_ symbol: String,
                            _ description: String,
                            _ tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
        .help(description)
        .accessibilityLabel(description)
    }

    private var installed: InstalledModel? {
        models.installed.first { $0.id == model.id }
    }

    private var isActive: Bool {
        coordinator.settingsStore.settings.activeModelID == model.id
    }

    private var subtitle: String {
        var parts = [model.tier.label, model.languages.label]
        if let installed {
            parts.append(Self.format(installed.sizeBytes) + " on disk")
        } else {
            parts.append(Self.format(model.approximateBytes) + " download")
        }
        if let note = model.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private func progressLabel(_ progress: DownloadProgress) -> String {
        "\(Self.format(progress.receivedBytes)) of "
        + "\(Self.format(progress.totalBytes)) · file "
        + "\(progress.completedFiles + 1) of \(progress.totalFiles)"
    }

    private func makeActive() {
        coordinator.settingsStore.settings.activeModelID = model.id
    }

    private func delete(_ installed: InstalledModel) {
        do {
            try models.delete(installed)
            deleteError = nil
            if isActive {
                coordinator.settingsStore.settings.activeModelID = nil
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Audio

private struct AudioTab: View {
    @Bindable var coordinator: AppCoordinator

    /// Picker tags cannot be nil, so "follow the system default" needs a
    /// sentinel. A CoreAudio UID never looks like this.
    private static let systemDefaultTag = "\u{0}system-default"

    private var defaultLabel: String {
        guard let systemDefault = coordinator.audioDevices.systemDefault else {
            return "System Default"
        }
        return "System Default (\(systemDefault.name))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: Binding(
                    get: { coordinator.selectedInputUID ?? Self.systemDefaultTag },
                    set: {
                        coordinator.selectInputDevice(
                            uid: $0 == Self.systemDefaultTag ? nil : $0)
                    })) {
                    Text(defaultLabel).tag(Self.systemDefaultTag)
                    Divider()
                    ForEach(coordinator.audioDevices.inputs) { device in
                        Label(device.name, systemImage: device.transport.symbolName)
                            .tag(device.id)
                    }
                    // A chosen-then-unplugged device keeps its row, or the
                    // picker would silently jump to something else.
                    if coordinator.selectedInputIsMissing,
                       let missing = coordinator.selectedInputUID {
                        Divider()
                        Text("Not connected").tag(missing)
                    }
                }

                LabeledContent("Level") {
                    ProgressView(value: Double(coordinator.inputLevel))
                        .frame(width: 160)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if coordinator.selectedInputIsMissing {
                        Label("That microphone is not connected. Clio will "
                              + "use the system default until it is back.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    // The spec asks the picker to carry this (§9).
                    if coordinator.effectiveInputDevice?.transport.degradesPlayback == true {
                        Label("Recording from a Bluetooth microphone switches "
                              + "the headset into call mode, so anything you "
                              + "are listening to drops in quality while you "
                              + "dictate. Keeping the headset as output and "
                              + "dictating into the built-in microphone avoids "
                              + "it.",
                              systemImage: "wave.3.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Trim silence before transcribing", isOn: Binding(
                    get: { coordinator.settingsStore.settings.voiceActivityDetection },
                    set: { coordinator.settingsStore.settings.voiceActivityDetection = $0 }))

                if coordinator.settingsStore.settings.voiceActivityDetection {
                    LabeledContent("Sensitivity") {
                        Slider(value: Binding(
                            get: { coordinator.settingsStore.settings.vadSensitivity },
                            set: { coordinator.settingsStore.settings.vadSensitivity = $0 }),
                               in: 0...1)
                        .frame(width: 160)
                    }
                    Text("Silence at either end is cut before transcribing, "
                         + "which is faster. Raise the sensitivity if quiet "
                         + "speech is being clipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Maximum length") {
                    // Minutes, not seconds. The cap runs to ten minutes, and
                    // in five-second steps that was 120 clicks from end to end
                    // for a number nobody sets to the second.
                    Stepper(
                        RecordingLimit.label(seconds:
                            coordinator.settingsStore.settings.maxRecordingSeconds),
                        value: Binding(
                            get: {
                                RecordingLimit.minutes(
                                    seconds: coordinator.settingsStore.settings.maxRecordingSeconds)
                            },
                            set: {
                                coordinator.settingsStore.settings.maxRecordingSeconds =
                                    RecordingLimit.seconds(minutes: $0)
                            }),
                        in: RecordingLimit.range, step: 1)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

private struct TranscriptionTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: Binding(
                    get: { coordinator.settingsStore.settings.language ?? "auto" },
                    set: { coordinator.settingsStore.settings.language = $0 == "auto" ? nil : $0 })) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Dutch").tag("nl")
                    Text("German").tag("de")
                    Text("French").tag("fr")
                    Text("Spanish").tag("es")
                }

                Toggle("Translate to English", isOn: Binding(
                    get: { coordinator.settingsStore.settings.translateToEnglish },
                    set: { coordinator.settingsStore.settings.translateToEnglish = $0 }))
            }

            Section {
                TextEditor(text: Binding(
                    get: { coordinator.settingsStore.settings.customVocabulary.joined(separator: "\n") },
                    set: {
                        coordinator.settingsStore.settings.customVocabulary =
                            $0.components(separatedBy: .newlines)
                    }))
                .font(.system(.body, design: .monospaced))
                .frame(height: 100)
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("One term per line. Fed to the model as an initial prompt so "
                     + "it spells names and jargon the way you do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Output

private struct OutputTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Picker("When finished", selection: Binding(
                    get: { coordinator.settingsStore.settings.outputAction },
                    set: { coordinator.settingsStore.settings.outputAction = $0 })) {
                    ForEach(OutputAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)

                if coordinator.settingsStore.settings.outputAction == .pasteAutomatically {
                    Picker("Method", selection: Binding(
                        get: { coordinator.settingsStore.settings.injectionMethod },
                        set: { coordinator.settingsStore.settings.injectionMethod = $0 })) {
                        ForEach(InjectionMethod.allCases, id: \.self) { method in
                            Text(method.label).tag(method)
                        }
                    }
                }
            } footer: {
                Text("The transcript always lands on the clipboard. Password "
                     + "fields and some terminals block synthetic keystrokes; "
                     + "there Clio copies instead and tells you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep the transcript on the clipboard", isOn: Binding(
                    get: { coordinator.settingsStore.settings.keepTranscriptOnClipboard },
                    set: { coordinator.settingsStore.settings.keepTranscriptOnClipboard = $0 }))
            } footer: {
                Text(coordinator.settingsStore.settings.outputAction == .copyOnly
                     ? "Copying always leaves it there."
                     : "Pasting borrows the clipboard and puts back what was "
                       + "there. Turn this on to keep the transcript instead — "
                       + "at the cost of replacing whatever you had copied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Trim trailing punctuation", isOn: Binding(
                    get: { coordinator.settingsStore.settings.trimTrailingPunctuation },
                    set: { coordinator.settingsStore.settings.trimTrailingPunctuation = $0 }))
                Toggle("Capitalize first letter", isOn: Binding(
                    get: { coordinator.settingsStore.settings.capitalizeFirstLetter },
                    set: { coordinator.settingsStore.settings.capitalizeFirstLetter = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Feedback

private struct FeedbackTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Picker("Overlay", selection: Binding(
                    get: { coordinator.settingsStore.settings.overlayPosition },
                    set: {
                        coordinator.settingsStore.settings.overlayPosition = $0
                        // Show it where it will actually sit. A corner is hard
                        // to picture from a radio button, and the pill is only
                        // ever on screen while dictating.
                        coordinator.previewOverlayPosition($0)
                    })) {
                    ForEach(OverlayPosition.allCases, id: \.self) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("Size", selection: Binding(
                    get: { coordinator.settingsStore.settings.pillSize },
                    set: {
                        coordinator.settingsStore.settings.pillSize = $0
                        coordinator.applySettings()
                        // Shown at the new size where it will sit, for the
                        // same reason the position is: "1.25×" is a number,
                        // and the pill is only otherwise seen while dictating.
                        coordinator.previewOverlayPosition(
                            coordinator.settingsStore.settings.overlayPosition)
                    })) {
                    ForEach(PillSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Translucency") {
                    HStack(spacing: 8) {
                        // Reversed: the slider runs from see-through to solid,
                        // which is the direction the label describes.
                        Slider(value: Binding(
                            get: { coordinator.settingsStore.settings.pillOpacity },
                            set: {
                                coordinator.settingsStore.settings.pillOpacity = $0
                                coordinator.applySettings()
                            }), in: 0...1)
                        .frame(width: 140)
                        Text("\(Int(coordinator.settingsStore.settings.pillOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                Toggle("Clear glass", isOn: Binding(
                    get: { coordinator.settingsStore.settings.pillClearGlass },
                    set: {
                        coordinator.settingsStore.settings.pillClearGlass = $0
                        coordinator.applySettings()
                    }))
            } footer: {
                Text("How solid the pill is. At the low end it is nearly bare "
                     + "glass and takes its colour from whatever is behind it — "
                     + "readable over a plain desktop, less so over a busy one. "
                     + "Clear glass drops the frosting as well, which is a "
                     + "different effect rather than simply less of this one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sound when recording starts", isOn: Binding(
                    get: { coordinator.settingsStore.settings.playSoundOnStart },
                    set: { coordinator.settingsStore.settings.playSoundOnStart = $0 }))
                Toggle("Play sound when recording stops", isOn: Binding(
                    get: { coordinator.settingsStore.settings.playSoundOnStop },
                    set: { coordinator.settingsStore.settings.playSoundOnStop = $0 }))
                Toggle("Play sound when cancelled", isOn: Binding(
                    get: { coordinator.settingsStore.settings.playSoundOnCancel },
                    set: { coordinator.settingsStore.settings.playSoundOnCancel = $0 }))
            }

            Section {
                Toggle("Keep history after quitting", isOn: Binding(
                    get: { coordinator.settingsStore.settings.keepHistoryOnDisk },
                    set: {
                        coordinator.settingsStore.settings.keepHistoryOnDisk = $0
                        coordinator.applySettings()
                    }))

                LabeledContent("Stored") {
                    Text("\(coordinator.history.entries.count) of "
                         + "\(HistoryStore.limit)")
                        .foregroundStyle(.secondary)
                }

                Button("Clear History") { coordinator.history.clear() }
                    .disabled(coordinator.history.entries.isEmpty)
            } header: {
                Text("History")
            } footer: {
                Text("The last \(HistoryStore.limit) transcripts are kept in "
                     + "memory so you can re-copy them. Writing them to disk is "
                     + "off by default — dictated text is whatever you said.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Self.appIcon
                            .resizable()
                            .frame(width: 96, height: 96)
                        Text("Clio")
                            .font(.title2.weight(.semibold))
                        Text("Native macOS dictation, entirely on this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Source") {
                    Link("github.com/petit-software/clio",
                         destination: URL(string: "https://github.com/petit-software/clio")!)
                }
                LabeledContent("Shortcut listener",
                               value: coordinator.isHotkeyRunning ? "Running" : "Stopped")
            }

            if let updates = coordinator.updates {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.automaticallyChecks = $0 }))

                    LabeledContent("Last checked") {
                        Text(updates.lastCheckDate.map {
                            $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? "Never")
                            .foregroundStyle(.secondary)
                    }

                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Clio is distributed outside the App Store, so this "
                         + "is how fixes reach you. Updates are downloaded only "
                         + "after you agree to them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.settingsStore.lastSaveError {
                Section {
                    Label("Settings could not be saved: \(error)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The artwork, not the bundle icon.
    ///
    /// Falls back to whatever the running app is using, so this still draws
    /// something in a preview — which has no bundle to load a resource from.
    private static var appIcon: Image {
        if let url = Bundle.main.url(forResource: "AboutIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        return Image(nsImage: NSApp.applicationIconImage ?? NSImage())
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "0.1") (\(build ?? "1"))"
    }
}

/// Shown in General and About, so a missing permission is visible wherever the
/// user happens to look — §7 asks for persistent but non-nagging.
struct PermissionBanner: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(title: "Microphone",
                state: coordinator.permissions.microphone,
                action: { Task { await coordinator.permissions.requestMicrophone() } },
                settingsAction: coordinator.permissions.openMicrophoneSettings)

            row(title: "Accessibility",
                state: coordinator.permissions.accessibility,
                action: coordinator.permissions.requestAccessibility,
                settingsAction: coordinator.permissions.openAccessibilitySettings)
        }
    }

    @ViewBuilder
    private func row(title: String,
                     state: PermissionState,
                     action: @escaping () -> Void,
                     settingsAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state.isGranted ? .green : .secondary)
            Text(title)
            Spacer()
            if !state.isGranted {
                Button(state == .notDetermined ? "Grant…" : "Open Settings…") {
                    state == .notDetermined ? action() : settingsAction()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
/// A configured install: permissions granted, a model on disk, two mics.
#Preview("Settings — configured") {
    SettingsView(coordinator: Preview.coordinator(
        transcripts: Preview.sampleTranscripts,
        settings: { $0.activeModelID = Preview.installedModel.id }))
}

/// A fresh install: nothing granted, nothing downloaded, one model mid-flight.
/// This is the state a new user actually sees, and the one easiest to forget.
#Preview("Settings — fresh install") {
    SettingsView(coordinator: Preview.freshCoordinator)
}

#Preview("Audio — Bluetooth warning") {
    SettingsView(coordinator: Preview.coordinator(
        devices: [Preview.builtInMic, Preview.headset],
        settings: { $0.inputDeviceUID = Preview.headset.id }))
}

/// The microphone the user chose is not plugged in.
#Preview("Audio — device unplugged") {
    SettingsView(coordinator: Preview.coordinator(
        devices: [Preview.builtInMic],
        settings: { $0.inputDeviceUID = "a-headset-that-is-not-here" }))
}

#Preview("Permission banner") {
    Form {
        Section("Nothing granted") {
            PermissionBanner(coordinator: Preview.coordinator(
                microphone: .notDetermined, accessibility: .notDetermined))
        }
        Section("Microphone only") {
            PermissionBanner(coordinator: Preview.coordinator(
                microphone: .granted, accessibility: .notDetermined))
        }
        Section("Denied — must go to System Settings") {
            PermissionBanner(coordinator: Preview.coordinator(
                microphone: .denied, accessibility: .denied))
        }
        Section("All granted") {
            PermissionBanner(coordinator: Preview.coordinator())
        }
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
#endif
