// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisperbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperbarCore", targets: ["WhisperbarCore"]),
        .executable(name: "Whisperbar", targets: ["Whisperbar"]),
    ],
    targets: [
        // Everything that is not SwiftUI: settings, permissions, the hotkey tap,
        // audio capture, transcription, text injection. Kept separate so the parts
        // with real logic are testable without standing up an app.
        .target(name: "WhisperbarCore"),
        // The app itself: menu bar, overlay panel, settings, onboarding.
        .executableTarget(name: "Whisperbar", dependencies: ["WhisperbarCore"]),
        .testTarget(name: "WhisperbarCoreTests", dependencies: ["WhisperbarCore"]),
    ]
)
