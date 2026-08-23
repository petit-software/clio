import AVFoundation
import AppKit
import Observation

public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined

    public var isGranted: Bool { self == .granted }
}

/// Microphone and Accessibility, polled.
///
/// Accessibility cannot be granted programmatically and can be revoked while
/// we run — §7. So this polls rather than checking once at launch, and the
/// menu bar and Settings both read the same live state.
@MainActor
@Observable
public final class PermissionsCoordinator {
    public private(set) var microphone: PermissionState = .notDetermined
    public private(set) var accessibility: PermissionState = .notDetermined

    public var allGranted: Bool {
        microphone.isGranted && accessibility.isGranted
    }

    /// Fires whenever Accessibility flips, so the app can reinstall the tap.
    public var onAccessibilityChange: ((Bool) -> Void)?

    private var pollTimer: Timer?

    public init() {
        refresh()
    }

    public func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }

        let trusted = AXIsProcessTrusted()
        let next: PermissionState = trusted ? .granted : .notDetermined
        if next != accessibility {
            accessibility = next
            onAccessibilityChange?(trusted)
        }
    }

    public func beginPolling(interval: TimeInterval = 2.0) {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Requests

    /// Prompts inline the first time; afterwards macOS ignores it and the user
    /// has to go to System Settings, which is why `openMicrophoneSettings`
    /// exists alongside.
    public func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    public func requestAccessibility() {
        HotkeyManager.requestAccessibilityTrust()
        beginPolling()
    }

    public func openAccessibilitySettings() {
        HotkeyManager.openAccessibilitySettings()
    }

    public func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
