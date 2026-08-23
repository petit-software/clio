// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisperbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperbarCore", targets: ["WhisperbarCore"]),
        .executable(name: "Whisperbar", targets: ["Whisperbar"]),
    ],
    dependencies: [
        // CoreML Whisper with an Apple Neural Engine path -- the whole reason
        // this app is native rather than a whisper.cpp wrapper. It also owns
        // model compilation and the Hugging Face layout we install into.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
    ],
    targets: [
        // Everything that is not SwiftUI: settings, permissions, the hotkey tap,
        // audio capture, transcription, text injection. Kept separate so the parts
        // with real logic are testable without standing up an app.
        .target(name: "WhisperbarCore",
                dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
        // The app itself: menu bar, overlay panel, settings, onboarding.
        .executableTarget(name: "Whisperbar", dependencies: ["WhisperbarCore"]),
        .testTarget(name: "WhisperbarCoreTests", dependencies: ["WhisperbarCore"]),
    ]
)
