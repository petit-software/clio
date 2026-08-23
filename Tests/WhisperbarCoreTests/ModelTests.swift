import Testing
import Foundation
@testable import WhisperbarCore

// MARK: - Helpers

/// A cache path that does not exist, so discovery cannot pick up whatever
/// models happen to be on the machine running the tests.
private let noCache = URL(fileURLWithPath: "/nonexistent/huggingface-cache")

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("whisperbar-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes bytes locally instead of reaching Hugging Face, so the download
/// orchestration is testable offline.
private final class StubTransport: ModelTransport, @unchecked Sendable {
    let files: [RemoteFile]
    var failOn: String?

    init(files: [RemoteFile], failOn: String? = nil) {
        self.files = files
        self.failOn = failOn
    }

    func list(repo: String, path: String) async throws -> [RemoteFile] {
        if files.isEmpty { throw ModelTransportError.emptyListing }
        return files
    }

    func download(repo: String, file: RemoteFile, to destination: URL,
                  onProgress: @Sendable @escaping (Int64) -> Void) async throws {
        if file.path == failOn {
            throw ModelTransportError.badResponse(500)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: Int(file.size))
        try data.write(to: destination)
        onProgress(file.size)
    }
}

private func remoteFiles(id: String) -> [RemoteFile] {
    [
        RemoteFile(path: "\(id)/AudioEncoder.mlmodelc/coremldata.bin", size: 512),
        RemoteFile(path: "\(id)/AudioEncoder.mlmodelc/model.mil", size: 2048),
        RemoteFile(path: "\(id)/TextDecoder.mlmodelc/coremldata.bin", size: 256),
        RemoteFile(path: "\(id)/config.json", size: 64),
    ]
}

// MARK: - Catalog

/// Resources/models.json in the checkout — the file build-app.sh copies into
/// the bundle. Located from #filePath so the test does not depend on where it
/// is run from.
private var repositoryCatalogURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperbarCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Resources/models.json")
}

@Test("The catalog shipped in the bundle loads and is non-empty")
func bundledCatalogLoads() throws {
    let models = try #require(ModelCatalog.decode(contentsOf: repositoryCatalogURL))
    #expect(models.isEmpty == false)
    #expect(models.contains { $0.id == ModelCatalog.defaultModelID })
}

/// The two can drift silently otherwise: the bundled file is what users get,
/// the constant is what they get when the bundle is missing.
@Test("The shipped catalog matches the built-in fallback")
func bundledMatchesBuiltIn() throws {
    let models = try #require(ModelCatalog.decode(contentsOf: repositoryCatalogURL))
    #expect(models == ModelCatalog.builtIn)
}

@Test("An override catalog on disk wins over the bundle")
func overrideCatalogWins() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let override = directory.appendingPathComponent("models.json")

    let custom = [CatalogModel(id: "custom", displayName: "Custom",
                               repo: "acme/models", approximateBytes: 1,
                               tier: .fast, languages: .english)]
    try JSONEncoder().encode(custom).write(to: override)

    #expect(ModelCatalog.load(overrideURL: override) == custom)
}

@Test("A corrupt override falls back rather than emptying the catalog")
func corruptOverrideFallsBack() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let override = directory.appendingPathComponent("models.json")
    try Data("nonsense".utf8).write(to: override)

    #expect(ModelCatalog.load(overrideURL: override).isEmpty == false)
}

// MARK: - Discovery

@MainActor
@Test("Only folders containing a compiled model count as installed")
func discoveryRequiresCompiledModel() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let good = root.appendingPathComponent("openai_whisper-tiny/AudioEncoder.mlmodelc")
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)

    // A half-finished download: a folder with loose files and no .mlmodelc.
    let partial = root.appendingPathComponent("half-downloaded")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: partial.appendingPathComponent("config.json"))

    let found = ModelManager.modelDirectories(in: root).map(\.lastPathComponent)
    #expect(found == ["openai_whisper-tiny"])
}

@MainActor
@Test("Directory size sums nested files")
func directorySizeIsRecursive() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let nested = root.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a/one.bin"))
    try Data(repeating: 0, count: 250).write(to: nested.appendingPathComponent("two.bin"))

    #expect(ModelManager.directorySize(of: root) == 350)
}

// MARK: - Download

@MainActor
@Test("A download installs every file and flattens the repo prefix")
func downloadInstallsFiles() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = "openai_whisper-tiny"
    let transport = StubTransport(files: remoteFiles(id: id))
    let manager = ModelManager(transport: transport, modelsDirectory: root,
                               huggingFaceCache: noCache)

    let model = CatalogModel(id: id, displayName: "Tiny",
                             repo: "argmaxinc/whisperkit-coreml",
                             approximateBytes: 2880, tier: .fast,
                             languages: .multilingual)
    manager.download(model)

    try await waitUntil { manager.isInstalled(id) }

    // The id must not appear twice in the path.
    let encoder = root.appendingPathComponent(
        "\(id)/AudioEncoder.mlmodelc/coremldata.bin")
    #expect(FileManager.default.fileExists(atPath: encoder.path))
    #expect(manager.downloads[id] == nil)
    #expect(manager.installed.first?.sizeBytes == 2880)
}

@MainActor
@Test("A failed download reports it and leaves nothing installed")
func failedDownloadCleansUp() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = "openai_whisper-tiny"
    let files = remoteFiles(id: id)
    let transport = StubTransport(files: files, failOn: files[2].path)
    let manager = ModelManager(transport: transport, modelsDirectory: root,
                               huggingFaceCache: noCache)

    manager.download(CatalogModel(id: id, displayName: "Tiny",
                                  repo: "argmaxinc/whisperkit-coreml",
                                  approximateBytes: 2880, tier: .fast,
                                  languages: .multilingual))

    try await waitUntil { manager.failures[id] != nil }

    #expect(manager.isInstalled(id) == false)
    #expect(manager.downloads[id] == nil)
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(id).path) == false)
}

@MainActor
@Test("Deleting is refused for models in the shared cache")
func deleteRefusesSharedCache() throws {
    let root = try makeTempDirectory()
    let elsewhere = try makeTempDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }

    let manager = ModelManager(transport: StubTransport(files: []),
                               modelsDirectory: root, huggingFaceCache: noCache)
    let shared = InstalledModel(id: "shared", displayName: "Shared",
                                sizeBytes: 1, url: elsewhere)

    #expect(manager.canDelete(shared) == false)
    #expect(throws: ModelManager.DeleteError.self) { try manager.delete(shared) }
    // The folder is still there.
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
}

@MainActor
@Test("Deleting removes a model we own")
func deleteRemovesOurs() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = "openai_whisper-tiny"
    let manager = ModelManager(transport: StubTransport(files: remoteFiles(id: id)),
                               modelsDirectory: root, huggingFaceCache: noCache)
    manager.download(CatalogModel(id: id, displayName: "Tiny",
                                  repo: "argmaxinc/whisperkit-coreml",
                                  approximateBytes: 2880, tier: .fast,
                                  languages: .multilingual))
    try await waitUntil { manager.isInstalled(id) }

    let model = try #require(manager.installed.first)
    #expect(manager.canDelete(model))
    try manager.delete(model)

    #expect(manager.isInstalled(id) == false)
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(id).path) == false)
}

// MARK: - Waiting

private func waitUntil(timeout: Duration = .seconds(5),
                       _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}

// MARK: - Containment

@MainActor
@Test("Containment is by path component, not string prefix")
func containmentIsNotStringPrefix() {
    let models = URL(fileURLWithPath: "/data/models")

    #expect(ModelManager.isDescendant(
        URL(fileURLWithPath: "/data/models/whisper-tiny"), of: models))
    // The trap a naive hasPrefix falls into.
    #expect(ModelManager.isDescendant(
        URL(fileURLWithPath: "/data/models-backup/whisper-tiny"), of: models) == false)
    // A directory is not a descendant of itself.
    #expect(ModelManager.isDescendant(models, of: models) == false)
    #expect(ModelManager.isDescendant(
        URL(fileURLWithPath: "/elsewhere/whisper-tiny"), of: models) == false)
}
