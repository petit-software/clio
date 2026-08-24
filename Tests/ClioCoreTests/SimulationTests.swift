import Testing
import Foundation
@testable import ClioCore

/// The seams the previews stand on.
///
/// A simulated dependency that quietly falls through to the real system is
/// worse than none: the preview looks right on the machine that wrote it and
/// shows something else everywhere else. These pin the fall-through shut.
@Suite("Simulation seams")
struct SimulationTests {

    @MainActor
    @Test("Simulated permissions report what they were given")
    func simulatedPermissionsAreFixed() {
        let denied = PermissionsCoordinator(simulating: .denied,
                                            accessibility: .notDetermined)
        #expect(denied.microphone == .denied)
        #expect(denied.accessibility == .notDetermined)
        #expect(denied.allGranted == false)

        let granted = PermissionsCoordinator(simulating: .granted,
                                             accessibility: .granted)
        #expect(granted.allGranted)
    }

    @MainActor
    @Test("Refreshing a simulated coordinator does not consult the system")
    func simulatedPermissionsIgnoreRefresh() {
        // This is the whole point: a preview of "microphone denied" has to
        // keep saying denied on a Mac where it is granted.
        let coordinator = PermissionsCoordinator(simulating: .denied,
                                                 accessibility: .denied)
        coordinator.refresh()
        #expect(coordinator.microphone == .denied)
        #expect(coordinator.accessibility == .denied)

        coordinator.beginPolling(interval: 0.01)
        #expect(coordinator.microphone == .denied)
    }

    @MainActor
    @Test("Requests are inert while simulated")
    func simulatedRequestsDoNothing() async {
        // A preview must never make the real system throw up a TCC prompt.
        let coordinator = PermissionsCoordinator(simulating: .notDetermined,
                                                 accessibility: .notDetermined)
        await coordinator.requestMicrophone()
        coordinator.requestAccessibility()
        #expect(coordinator.microphone == .notDetermined)
    }

    @MainActor
    @Test("A simulated device monitor reports its fixed list")
    func simulatedDevicesAreFixed() {
        let headset = AudioInputDevice(id: "bt", name: "AirPods Pro", deviceID: 7,
                                       transport: .bluetooth, isSystemDefault: true)
        let monitor = AudioDeviceMonitor(simulating: [headset])

        #expect(monitor.inputs.map(\.id) == ["bt"])
        #expect(monitor.systemDefault?.id == "bt")

        // Refreshing must not reach for whatever is plugged into this machine.
        monitor.refresh()
        #expect(monitor.inputs.map(\.id) == ["bt"])
    }

    @MainActor
    @Test("A simulated monitor still answers selection questions correctly")
    func simulatedMonitorResolves() {
        let mic = AudioInputDevice(id: "built-in", name: "Built-in", deviceID: 1,
                                   transport: .builtIn, isSystemDefault: true)
        let monitor = AudioDeviceMonitor(simulating: [mic])

        #expect(monitor.resolved(uid: nil)?.id == "built-in")
        #expect(monitor.resolved(uid: "built-in")?.id == "built-in")
        #expect(monitor.isMissing(uid: "gone"))
        #expect(monitor.resolved(uid: "gone")?.id == "built-in")
    }

    @MainActor
    @Test("An empty simulated monitor has no default and does not crash")
    func simulatedMonitorCanBeEmpty() {
        let monitor = AudioDeviceMonitor(simulating: [])
        #expect(monitor.inputs.isEmpty)
        #expect(monitor.systemDefault == nil)
        #expect(monitor.resolved(uid: nil) == nil)
    }

    @MainActor
    @Test("A simulated model manager reports its fixed state, scanning nothing")
    func simulatedModelsAreFixed() {
        let installed = InstalledModel(id: "distil", displayName: "Distil",
                                       sizeBytes: 595_000_000,
                                       url: URL(fileURLWithPath: "/preview"))
        let manager = ModelManager.simulating(
            installed: [installed],
            downloads: ["small": DownloadProgress(receivedBytes: 1, totalBytes: 2,
                                                  completedFiles: 1, totalFiles: 2)])

        #expect(manager.installed.map(\.id) == ["distil"])
        #expect(manager.isInstalled("distil"))
        #expect(manager.isDownloading("small"))
        #expect(!manager.catalog.isEmpty)

        // Its directory does not exist, so a rescan empties it rather than
        // discovering this machine's real models.
        manager.refreshInstalled()
        #expect(manager.installed.isEmpty)
    }

    @MainActor
    @Test("A simulated model manager will not delete anything real")
    func simulatedModelsCannotDelete() {
        let manager = ModelManager.simulating()
        let real = InstalledModel(id: "x", displayName: "X", sizeBytes: 1,
                                  url: AppPaths.modelsDirectory
                                      .appendingPathComponent("x"))
        // Its models directory is a path that does not exist, so nothing on
        // this machine is inside it.
        #expect(manager.canDelete(real) == false)
    }
}
