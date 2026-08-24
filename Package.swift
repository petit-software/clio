// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"]),
        .executable(name: "Scribe", targets: ["Scribe"]),
    ],
    dependencies: [
        // CoreML Whisper with an Apple Neural Engine path -- the whole reason
        // this app is native rather than a whisper.cpp wrapper. It also owns
        // model compilation and the Hugging Face layout we install into.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        // Updates. Scribe ships outside the App Store, so nothing else will
        // deliver a fix to someone who already downloaded it. Sparkle owns the
        // parts that are easy to get wrong: a resumed or corrupt download,
        // atomic replacement, and not installing over a running copy.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Everything that is not SwiftUI: settings, permissions, the hotkey tap,
        // audio capture, transcription, text injection. Kept separate so the parts
        // with real logic are testable without standing up an app.
        .target(name: "ScribeCore",
                dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
        // The app itself: menu bar, overlay panel, settings, onboarding.
        .executableTarget(name: "Scribe",
                          dependencies: [
                              "ScribeCore",
                              .product(name: "Sparkle", package: "Sparkle"),
                          ]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
    ]
)
