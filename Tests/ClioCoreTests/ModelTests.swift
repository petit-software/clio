import Testing
import Foundation
@testable import ClioCore

// MARK: - Helpers

/// A cache path that does not exist, so discovery cannot pick up whatever
/// models happen to be on the machine running the tests.
private let noCache = URL(fileURLWithPath: "/nonexistent/huggingface-cache")

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-models-\(UUID().uuidString)")
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
        .deletingLastPathComponent()   // ClioCoreTests
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

@Test("A catalog written before retired existed still decodes, as speech models")
func catalogWithoutRetiredDecodes() throws {
    let json = """
    [{"id": "m", "displayName": "M", "repo": "acme/models",
      "approximateBytes": 1, "tier": "fast", "languages": "english"}]
    """
    let models = try JSONDecoder().decode([CatalogModel].self, from: Data(json.utf8))
    #expect(models.first?.retired == false)
    #expect(models.first?.kind == .speech)
    #expect(models.first?.fileName == nil)
    #expect(models.first?.repoPath == "m")
}

@Test("The shipped catalog offers summary models: one GGUF each, listed from the repo's root")
func catalogHasSummaryModels() throws {
    let models = try #require(ModelCatalog.decode(contentsOf: repositoryCatalogURL))
    let language = models.filter { $0.kind == .language }
    #expect(!language.isEmpty)
    #expect(language.allSatisfy { $0.fileName?.hasSuffix(".gguf") == true && $0.repoPath == "" })
    #expect(language.contains { $0.id == ModelCatalog.defaultSummaryModelID })
    #expect(models.filter { $0.kind == .speech }.contains { $0.id == ModelCatalog.defaultModelID })
}

@MainActor
@Test("Each tab lists its own kind")
func listedByKind() {
    let speech = CatalogModel(id: "s", displayName: "S", repo: "acme/models",
                              approximateBytes: 1, tier: .fast, languages: .english)
    let language = CatalogModel(id: "l", displayName: "L", repo: "acme/models",
                                approximateBytes: 1, tier: .best, languages: .multilingual,
                                kind: .language, fileName: "l.gguf")
    let manager = ModelManager.simulating(
        catalog: [speech, language],
        installed: [InstalledModel(id: "l", displayName: "L", sizeBytes: 1,
                                   url: URL(fileURLWithPath: "/nonexistent/l"), kind: .language)])
    #expect(manager.listedCatalog(.speech).map(\.id) == ["s"])
    #expect(manager.listedCatalog(.language).map(\.id) == ["l"])
    #expect(manager.installed(.speech).isEmpty)
    #expect(manager.installed(.language).map(\.id) == ["l"])
}

@MainActor
@Test("A retired model is listed only while it is installed")
func retiredModelListedOnlyWhenInstalled() {
    let offered = CatalogModel(id: "offered", displayName: "Offered",
                               repo: "acme/models", approximateBytes: 1,
                               tier: .fast, languages: .english)
    var gone = offered
    gone.id = "gone"
    gone.retired = true

    let absent = ModelManager.simulating(catalog: [offered, gone])
    #expect(absent.listedCatalog.map(\.id) == ["offered"])

    let present = ModelManager.simulating(
        catalog: [offered, gone],
        installed: [InstalledModel(id: "gone", displayName: "Gone", sizeBytes: 1,
                                   url: URL(fileURLWithPath: "/nonexistent/gone"))])
    #expect(present.listedCatalog.map(\.id) == ["offered", "gone"])
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
@Test("A folder holding a GGUF is an installed language model; compiled models are speech")
func discoveryTellsKindsApart() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let speech = root.appendingPathComponent("openai_whisper-tiny/AudioEncoder.mlmodelc")
    try FileManager.default.createDirectory(at: speech, withIntermediateDirectories: true)
    let language = root.appendingPathComponent("qwen")
    try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: language.appendingPathComponent("Qwen-Q4_K_M.gguf"))
    // Still downloading: not a model yet.
    let partial = root.appendingPathComponent("gemma")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: partial.appendingPathComponent("gemma.gguf.partial"))

    let found = ModelManager.modelDirectories(in: root).map(\.lastPathComponent).sorted()
    #expect(found == ["openai_whisper-tiny", "qwen"])
    #expect(ModelManager.kind(of: speech.deletingLastPathComponent()) == .speech)
    #expect(ModelManager.kind(of: language) == .language)

    let manager = ModelManager(transport: StubTransport(files: []), modelsDirectory: root,
                               huggingFaceCache: noCache)
    let installed = try #require(manager.installedModel(id: "qwen"))
    #expect(installed.kind == .language)
    #expect(installed.weightsFile?.lastPathComponent == "Qwen-Q4_K_M.gguf")
    #expect(manager.installedModel(id: "openai_whisper-tiny")?.weightsFile == nil)
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
@Test("A single-file model takes one file from the repo's root into a folder of its own")
func downloadInstallsOneFile() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // The repo root: every quantization, and a README.
    let transport = StubTransport(files: [
        RemoteFile(path: "Model-Q4_K_M.gguf", size: 1024),
        RemoteFile(path: "Model-Q8_0.gguf", size: 2048),
        RemoteFile(path: "README.md", size: 10),
    ])
    let manager = ModelManager(transport: transport, modelsDirectory: root,
                               huggingFaceCache: noCache)
    let model = CatalogModel(id: "model-q4_k_m", displayName: "Model", repo: "acme/Model-GGUF",
                             approximateBytes: 1024, tier: .balanced, languages: .multilingual,
                             kind: .language, fileName: "Model-Q4_K_M.gguf")
    manager.download(model)
    try await waitUntil { manager.isInstalled(model.id) }

    let folder = root.appendingPathComponent(model.id)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Model-Q4_K_M.gguf"])
    let installed = try #require(manager.installedModel(id: model.id))
    #expect(installed.kind == .language)
    #expect(installed.sizeBytes == 1024)
    #expect(installed.weightsFile?.standardizedFileURL.path
            == folder.appendingPathComponent("Model-Q4_K_M.gguf").standardizedFileURL.path)
}

@MainActor
@Test("A single-file model whose file the repo no longer has fails, and installs nothing")
func downloadOfMissingFileFails() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = ModelManager(
        transport: StubTransport(files: [RemoteFile(path: "Other.gguf", size: 1)]),
        modelsDirectory: root, huggingFaceCache: noCache)
    let model = CatalogModel(id: "m", displayName: "M", repo: "acme/M", approximateBytes: 1,
                             tier: .fast, languages: .english, kind: .language, fileName: "M.gguf")
    manager.download(model)
    try await waitUntil { manager.failures[model.id] != nil }
    #expect(manager.isInstalled(model.id) == false)
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

// MARK: - Models from elsewhere

@MainActor
@Test("A WhisperKit folder elsewhere is linked, not copied; Delete removes the link alone")
func linkSpeechModel() throws {
    let root = try makeTempDirectory()
    let elsewhere = try makeTempDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    let source = elsewhere.appendingPathComponent("my-whisper")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("AudioEncoder.mlmodelc"),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0, count: 300).write(to: source.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin"))

    let manager = ModelManager(transport: StubTransport(files: []), modelsDirectory: root,
                               huggingFaceCache: noCache)
    let installed = try manager.link(source, as: .speech)
    #expect(installed.id == "my-whisper")
    #expect(installed.kind == .speech)
    #expect(installed.isLinked)
    #expect(installed.sizeBytes == 300)
    #expect(installed.resolvedURL.standardizedFileURL.path == source.resolvingSymlinksInPath().path)
    #expect(manager.canDelete(installed))
    #expect(throws: ModelManager.LinkError.self) { try manager.link(source, as: .speech) }
    // Not a model folder, not a GGUF.
    #expect(throws: ModelManager.LinkError.self) { try manager.link(elsewhere, as: .speech) }
    #expect(throws: ModelManager.LinkError.self) { try manager.link(source, as: .language) }

    try manager.delete(installed)
    #expect(manager.isInstalled("my-whisper") == false)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin").path))
}

@MainActor
@Test("A GGUF elsewhere is linked into a folder of its own, and is a language model")
func linkLanguageModel() throws {
    let root = try makeTempDirectory()
    let elsewhere = try makeTempDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    let source = elsewhere.appendingPathComponent("Qwen-Q4_K_M.gguf")
    try Data(repeating: 0, count: 2_000).write(to: source)

    let manager = ModelManager(transport: StubTransport(files: []), modelsDirectory: root,
                               huggingFaceCache: noCache)
    let installed = try manager.link(source, as: .language)
    #expect(installed.id == "Qwen-Q4_K_M")
    #expect(installed.kind == .language)
    #expect(installed.isLinked)
    #expect(installed.sizeBytes == 2_000)
    #expect(installed.weightsFile?.lastPathComponent == "Qwen-Q4_K_M.gguf")
    #expect(installed.resolvedURL.standardizedFileURL.path == source.resolvingSymlinksInPath().path)
    #expect(manager.otherInstalled(.language).map(\.id) == ["Qwen-Q4_K_M"])
    #expect(manager.canDelete(installed))

    try manager.delete(installed)
    #expect(manager.installed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

// MARK: - Installed-set change notification

@MainActor
@Test("Installing and deleting notify, an unchanged rescan does not")
func installedChangesAreAnnounced() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let id = "openai_whisper-tiny"
    let manager = ModelManager(transport: StubTransport(files: remoteFiles(id: id)),
                               modelsDirectory: root, huggingFaceCache: noCache)
    var notifications = 0
    manager.onInstalledChanged = { notifications += 1 }

    manager.download(CatalogModel(id: id, displayName: "Tiny",
                                  repo: "argmaxinc/whisperkit-coreml",
                                  approximateBytes: 2880, tier: .fast,
                                  languages: .multilingual))
    try await waitUntil { manager.isInstalled(id) }
    #expect(notifications == 1)

    // A rescan that finds the same thing must stay quiet, or anything
    // listening reconciles in a loop.
    manager.refreshInstalled()
    #expect(notifications == 1)

    try manager.delete(try #require(manager.installed.first))
    #expect(notifications == 2)
}
