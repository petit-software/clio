import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import WhisperbarCore

/// The tabs from §6. Model and Audio-device pickers are intentionally thin
/// here — ModelManager is Milestone 4 — but every control that Milestone 0 can
/// honestly back is wired to the store.
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
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
                .tabItem { Label("Output", systemImage: "arrow.right.doc.on.clipboard") }
            FeedbackTab(coordinator: coordinator)
                .tabItem { Label("Feedback", systemImage: "bell") }
            AboutTab(coordinator: coordinator)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HotkeyRecorder(coordinator: coordinator)
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

                if coordinator.settingsStore.settings.hotkey.requiresAppleKeyboard {
                    Label("The fn (Globe) key only reports on Apple keyboards.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { coordinator.settingsStore.settings.launchAtLogin },
                    set: { newValue in
                        coordinator.settingsStore.settings.launchAtLogin = newValue
                        setLaunchAtLogin(newValue)
                    }))

                Toggle("Show icon in menu bar", isOn: Binding(
                    get: { coordinator.settingsStore.settings.showMenuBarIcon },
                    set: { coordinator.settingsStore.settings.showMenuBarIcon = $0 }))
            }

            if !coordinator.permissions.allGranted {
                Section {
                    PermissionBanner(coordinator: coordinator)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert rather than show a toggle that does not match reality.
            coordinator.settingsStore.settings.launchAtLogin = !enabled
        }
    }
}

/// Records the next chord the user presses.
///
/// A local NSEvent monitor is enough here — Settings is focused when it's in
/// use, so this does not need the global tap.
private struct HotkeyRecorder: View {
    @Bindable var coordinator: AppCoordinator
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(isRecording
                 ? "Press a shortcut…"
                 : coordinator.settingsStore.settings.hotkey.displayString)
                .frame(minWidth: 120)
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.type == .keyDown {
                guard event.keyCode != UInt16(kVK_Escape) else {
                    stopRecording()
                    return nil
                }
                commit(Hotkey(keyCode: event.keyCode, modifierFlags: flags.rawValue))
                return nil
            }

            // Modifier-only chord: committed once the user has actually held
            // something, so a stray Shift while reaching for the key is not it.
            if !flags.isEmpty {
                commit(Hotkey(keyCode: nil, modifierFlags: flags.rawValue))
            }
            return nil
        }
    }

    private func commit(_ hotkey: Hotkey) {
        coordinator.settingsStore.settings.hotkey = hotkey
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

    var body: some View {
        Form {
            Section {
                Label("No models installed yet.", systemImage: "shippingbox")
                Text("Model download and selection arrive with the WhisperKit "
                     + "engine in Milestone 2. Until then dictation runs against "
                     + "a stub that returns placeholder text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Installed")
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

private struct AudioTab: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent("Input") {
                    Text("System default")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Level") {
                    ProgressView(value: Double(coordinator.inputLevel))
                        .frame(width: 160)
                }
            }

            Section {
                Toggle("Voice activity detection", isOn: Binding(
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
                }

                LabeledContent("Maximum length") {
                    Stepper(
                        "\(Int(coordinator.settingsStore.settings.maxRecordingSeconds))s",
                        value: Binding(
                            get: { coordinator.settingsStore.settings.maxRecordingSeconds },
                            set: { coordinator.settingsStore.settings.maxRecordingSeconds = $0 }),
                        in: 5...600, step: 5)
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
                     + "there Whisperbar copies instead and tells you.")
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
                    set: { coordinator.settingsStore.settings.overlayPosition = $0 })) {
                    ForEach(OverlayPosition.allCases, id: \.self) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)
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
                LabeledContent("Version", value: Self.version)
                LabeledContent("Shortcut listener",
                               value: coordinator.isHotkeyRunning ? "Running" : "Stopped")
            }

            Section {
                PermissionBanner(coordinator: coordinator)
            } header: {
                Text("Permissions")
            }

            Section {
                LabeledContent("Models") {
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
