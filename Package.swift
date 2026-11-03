// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClioCore", targets: ["ClioCore"]),
        .library(name: "ClioUI", targets: ["ClioUI"]),
        .executable(name: "Clio", targets: ["Clio"]),
    ],
    dependencies: [
        // CoreML Whisper with an Apple Neural Engine path -- the whole reason
        // this app is native rather than a whisper.cpp wrapper. It also owns
        // model compilation and the Hugging Face layout we install into.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        // Updates. Clio ships outside the App Store, so nothing else will
        // deliver a fix to someone who already downloaded it. Sparkle owns the
        // parts that are easy to get wrong: a resumed or corrupt download,
        // atomic replacement, and not installing over a running copy.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Everything that is not SwiftUI: settings, permissions, the hotkey tap,
        // audio capture, transcription, text injection. Kept separate so the parts
        // with real logic are testable without standing up an app.
        .target(name: "ClioCore",
                dependencies: [
                    "ClioObjC",
                    "llama",
                    .product(name: "WhisperKit", package: "WhisperKit"),
                ]),
        // llama.cpp, prebuilt by its own project for every release: the
        // runtime for a downloaded summary model (LocalSummaryModel). A
        // binary because the alternative, MLX, compiles its Metal shaders
        // only under Xcode, and `swift build` is how this app is built and
        // tested. The framework is dynamic, so build-app.sh embeds it
        // beside Sparkle.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12069/llama-b12069-xcframework.zip",
            checksum: "6323ec9777dd6f04f2cfb396d02989f26feec06d2e336d21c2a1b7fc1bf434e8"),
        // One Objective-C function: run a block and catch the NSException
        // it may raise. Swift cannot; AVAudioEngine throws them; see
        // ObjCException.swift in ClioCore for the why.
        .target(name: "ClioObjC"),
        // The app itself: menu bar, overlay panel, settings, onboarding.
        // Every SwiftUI view lives here rather than in the executable, so that
        // Xcode can render its #Preview blocks: previews are dependable in a
        // library target and flaky in an executable one.
        .target(name: "ClioUI",
                dependencies: [
                    "ClioCore",
                    .product(name: "Sparkle", package: "Sparkle"),
                ]),
        // Nothing but @main and the app delegate.
        .executableTarget(name: "Clio", dependencies: ["ClioUI"]),
        .testTarget(name: "ClioCoreTests", dependencies: ["ClioCore"]),
    ]
)
