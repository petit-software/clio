#if DEBUG
import Foundation
import ClioCore

/// Fixtures for Xcode previews.
///
/// Every dependency here is simulated. That is the whole point: a preview of
/// the onboarding window has to be able to show "microphone denied" on a Mac
/// where it is granted, and a preview of the model list must not depend on
/// what this machine happens to have downloaded.
///
/// DEBUG-only, so none of it ships.
@MainActor
enum Preview {

    // MARK: Devices

    static let builtInMic = AudioInputDevice(
        id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        deviceID: 81, transport: .builtIn, isSystemDefault: false)

    static let displayMic = AudioInputDevice(
        id: "AppleUSBAudioEngine:Studio Display", name: "Studio Display Microphone",
        deviceID: 99, transport: .usb, isSystemDefault: true)

    static let headset = AudioInputDevice(
        id: "bluetooth-headset", name: "AirPods Pro",
        deviceID: 120, transport: .bluetooth, isSystemDefault: false)

    // MARK: Models

    static var installedModel: InstalledModel {
        InstalledModel(id: "distil-whisper_distil-large-v3_594MB",
                       displayName: "Distil Large v3",
                       sizeBytes: 595_000_000,
                       url: URL(fileURLWithPath: "/preview/models/distil"))
    }

    static var downloadInFlight: DownloadProgress {
        DownloadProgress(receivedBytes: 143_000_000, totalBytes: 217_000_000,
                         completedFiles: 12, totalFiles: 19)
    }

    // MARK: Coordinators

    /// A settings store backed by a throwaway file, so previews never touch
    /// the real one.
    private static func scratchSettings(
        _ configure: (inout Settings) -> Void = { _ in }
    ) -> SettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-preview-\(UUID().uuidString).json")
        let store = SettingsStore(fileURL: url)
        configure(&store.settings)
        return store
    }

    static func coordinator(
        microphone: PermissionState = .granted,
        accessibility: PermissionState = .granted,
        devices: [AudioInputDevice] = [builtInMic, displayMic],
        installed: [InstalledModel] = [installedModel],
        downloads: [String: DownloadProgress] = [:],
        transcripts: [String] = [],
        settings: (inout Settings) -> Void = { _ in }
    ) -> AppCoordinator {
        let store = scratchSettings(settings)
        let history = HistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("clio-preview-history-\(UUID().uuidString).json"))
        for text in transcripts { history.add(text) }

        return AppCoordinator(
            settingsStore: store,
            permissions: PermissionsCoordinator(simulating: microphone,
                                                accessibility: accessibility),
            models: ModelManager.simulating(installed: installed,
                                            downloads: downloads),
            audioDevices: AudioDeviceMonitor(simulating: devices),
            history: history,
            engine: StubTranscriptionEngine())
    }

    /// A fresh install: nothing granted, nothing downloaded.
    static var freshCoordinator: AppCoordinator {
        coordinator(microphone: .notDetermined,
                    accessibility: .notDetermined,
                    installed: [],
                    downloads: ["openai_whisper-small_216MB": downloadInFlight])
    }

    static let sampleTranscripts = [
        "Let's ship the microphone picker before the icon work.",
        "Remember to re-grant accessibility after the next build.",
        "The quick brown fox jumps over the lazy dog.",
    ]
}
#endif
