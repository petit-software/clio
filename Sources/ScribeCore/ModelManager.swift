import Foundation
import Observation

/// Progress for one in-flight download.
public struct DownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var completedFiles: Int
    public var totalFiles: Int

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

/// The model catalog, what's installed, and moving between the two (§5.5).
///
/// Installed models are discovered from disk rather than tracked in settings:
/// the folder either exists and is complete or it doesn't, and that survives a
/// settings reset, a manual drop-in, and a model another tool downloaded.
@MainActor
@Observable
public final class ModelManager {

    public private(set) var catalog: [CatalogModel] = []
    public private(set) var installed: [InstalledModel] = []
    public private(set) var downloads: [String: DownloadProgress] = [:]
    public private(set) var failures: [String: String] = [:]

    private let transport: any ModelTransport
    private let modelsDirectory: URL
    private let huggingFaceCache: URL
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(transport: any ModelTransport = HuggingFaceTransport(),
                modelsDirectory: URL = AppPaths.modelsDirectory,
                huggingFaceCache: URL = AppPaths.huggingFaceCache) {
        self.transport = transport
        self.modelsDirectory = modelsDirectory
        self.huggingFaceCache = huggingFaceCache
        self.catalog = ModelCatalog.load()
        refreshInstalled()
    }

    // MARK: Discovery

    /// Rescans both our own models directory and the shared Hugging Face
    /// cache, so a model another tool already downloaded is not downloaded
    /// again.
    public func refreshInstalled() {
        var found: [String: InstalledModel] = [:]

        for url in Self.modelDirectories(in: modelsDirectory) {
            let id = url.lastPathComponent
            found[id] = InstalledModel(id: id,
                                       displayName: displayName(for: id),
                                       sizeBytes: Self.directorySize(of: url),
                                       url: url)
        }

        // Ours wins on a tie: we can delete our own copy, never the shared one.
        for url in Self.huggingFaceModelDirectories(cache: huggingFaceCache) {
            let id = url.lastPathComponent
            guard found[id] == nil else { continue }
            found[id] = InstalledModel(id: id,
                                       displayName: displayName(for: id),
                                       sizeBytes: Self.directorySize(of: url),
                                       url: url)
        }

        installed = found.values.sorted { $0.displayName < $1.displayName }
    }

    public func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    public func installedModel(id: String?) -> InstalledModel? {
        guard let id else { return nil }
        return installed.first { $0.id == id }
    }

    /// A model folder is one containing at least one compiled Core ML model.
    /// That is also what makes a half-finished download not count as installed.
    static func modelDirectories(in root: URL) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        return entries.filter { url in
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            let contents = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return contents.contains { $0.hasSuffix(".mlmodelc") }
        }
    }

    /// `~/.cache/huggingface/hub/models--<org>--<repo>/snapshots/<rev>/<model>/`
    static func huggingFaceModelDirectories(
        cache: URL = AppPaths.huggingFaceCache
    ) -> [URL] {
        let manager = FileManager.default
        guard let repos = try? manager.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil)
        else { return [] }

        var result: [URL] = []
        for repo in repos where repo.lastPathComponent.hasPrefix("models--") {
            let snapshots = repo.appendingPathComponent("snapshots")
            guard let revisions = try? manager.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: nil) else { continue }
            for revision in revisions {
                result.append(contentsOf: modelDirectories(in: revision))
            }
        }
        return result
    }

    static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            total += Int64(size ?? 0)
        }
        return total
    }

    private func displayName(for id: String) -> String {
        catalog.first { $0.id == id }?.displayName ?? id
    }

    // MARK: Download

    public func isDownloading(_ id: String) -> Bool {
        downloads[id] != nil
    }

    public func download(_ model: CatalogModel) {
        guard tasks[model.id] == nil, !isInstalled(model.id) else { return }

        failures[model.id] = nil
        downloads[model.id] = DownloadProgress(receivedBytes: 0, totalBytes: 0,
                                               completedFiles: 0, totalFiles: 0)

        tasks[model.id] = Task { [weak self] in
            await self?.performDownload(model)
        }
    }

    public func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        downloads[id] = nil
        // A cancelled download leaves a partial folder that would otherwise
        // read as installed on the next scan.
        try? FileManager.default.removeItem(
            at: modelsDirectory.appendingPathComponent(id))
        refreshInstalled()
    }

    /// Where the tokenizer for an installed model lives.
    ///
    /// A subfolder rather than the model folder itself: the tokenizer repo has
    /// its own `config.json`, and dropping that next to WhisperKit's would
    /// overwrite it.
    public nonisolated static func tokenizerDirectory(for model: InstalledModel) -> URL {
        model.url.appendingPathComponent("tokenizer", isDirectory: true)
    }

    /// Model weights only — the tokenizer repo also carries PyTorch, TF and
    /// ONNX copies of the model that we have no use for.
    static let weightExtensions: Set<String> = [
        "bin", "safetensors", "msgpack", "h5", "onnx", "ot", "pt", "ckpt",
    ]

    private func performDownload(_ model: CatalogModel) async {
        defer { tasks[model.id] = nil }

        do {
            var files = try await transport.list(repo: model.repo, path: model.id)
                .map { (file: $0, subdirectory: String?.none) }

            if let tokenizerRepo = model.tokenizerRepo {
                let tokenizerFiles = try await transport.list(repo: tokenizerRepo, path: "")
                    .filter { file in
                        let ext = (file.path as NSString).pathExtension.lowercased()
                        return !Self.weightExtensions.contains(ext)
                    }
                files.append(contentsOf: tokenizerFiles.map { (file: $0, subdirectory: "tokenizer") })
            }

            let total = files.reduce(Int64(0)) { $0 + $1.file.size }
            // Captured as a plain Int: the progress callback is @Sendable, and
            // reaching into `files` from inside it would send a non-Sendable
            // array across isolation.
            let fileCount = files.count
            downloads[model.id] = DownloadProgress(
                receivedBytes: 0, totalBytes: total,
                completedFiles: 0, totalFiles: fileCount)

            let destinationRoot = modelsDirectory.appendingPathComponent(model.id)
            try FileManager.default.createDirectory(
                at: destinationRoot, withIntermediateDirectories: true)

            var completedBytes: Int64 = 0

            for (index, entry) in files.enumerated() {
                try Task.checkCancellation()
                let file = entry.file

                // Paths in the listing are repo-relative and start with the
                // model id; strip it so the folder is not nested twice.
                let relative = file.path.hasPrefix(model.id + "/")
                    ? String(file.path.dropFirst(model.id.count + 1))
                    : file.path
                let destination = entry.subdirectory
                    .map { destinationRoot.appendingPathComponent($0)
                                          .appendingPathComponent(relative) }
                    ?? destinationRoot.appendingPathComponent(relative)

                // Already there and the right size — a retry after a failure
                // resumes at file granularity rather than starting over.
                if let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]),
                   Int64(existing.fileSize ?? 0) == file.size {
                    completedBytes += file.size
                    downloads[model.id] = DownloadProgress(
                        receivedBytes: completedBytes, totalBytes: total,
                        completedFiles: index + 1, totalFiles: fileCount)
                    continue
                }

                let base = completedBytes
                let sourceRepo = entry.subdirectory == nil
                    ? model.repo
                    : (model.tokenizerRepo ?? model.repo)
                try await transport.download(
                    repo: sourceRepo, file: file, to: destination
                ) { [weak self] received in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloads[model.id] != nil else { return }
                        self.downloads[model.id] = DownloadProgress(
                            receivedBytes: base + received, totalBytes: total,
                            completedFiles: index, totalFiles: fileCount)
                    }
                }

                completedBytes += file.size
                downloads[model.id] = DownloadProgress(
                    receivedBytes: completedBytes, totalBytes: total,
                    completedFiles: index + 1, totalFiles: fileCount)
            }

            downloads[model.id] = nil
            refreshInstalled()

        } catch is CancellationError {
            downloads[model.id] = nil
        } catch {
            downloads[model.id] = nil
            failures[model.id] = error.localizedDescription
            // Partial folders are cleared so they cannot be mistaken for an
            // install; the next attempt starts clean.
            try? FileManager.default.removeItem(
                at: modelsDirectory.appendingPathComponent(model.id))
            refreshInstalled()
        }
    }

    // MARK: Delete

    public enum DeleteError: LocalizedError {
        case notOurs

        public var errorDescription: String? {
            "That model lives in the shared Hugging Face cache. Scribe "
            + "will not delete it, because other tools may be using it."
        }
    }

    /// Only ever deletes from our own models directory. A model discovered in
    /// the shared cache belongs to whatever put it there.
    public func delete(_ model: InstalledModel) throws {
        guard canDelete(model) else { throw DeleteError.notOurs }
        try FileManager.default.removeItem(at: model.url)
        refreshInstalled()
    }

    public func canDelete(_ model: InstalledModel) -> Bool {
        Self.isDescendant(model.url, of: modelsDirectory)
    }

    /// Containment by path components, not by string prefix.
    ///
    /// A string prefix gets this wrong twice: FileManager hands back resolved
    /// paths (`/private/var/…`) where our own URL is still the symlink
    /// (`/var/…`), and `…/models` is a textual prefix of `…/models-backup`.
    /// Deleting is destructive, so it does not get to be approximately right.
    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        guard target.count > root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }
}
