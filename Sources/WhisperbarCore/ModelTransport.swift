import CryptoKit
import Foundation

/// One file inside a model folder on the remote.
public struct RemoteFile: Sendable, Equatable {
    public var path: String        // full path within the repo
    public var size: Int64
    /// Hugging Face reports an LFS `oid`, which is the file's SHA-256. Small
    /// non-LFS files have none, and are verified by size alone.
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// The network seam.
///
/// A protocol so the download orchestration can be tested without reaching
/// Hugging Face — the tests drive a stub that writes bytes locally.
public protocol ModelTransport: Sendable {
    func list(repo: String, path: String) async throws -> [RemoteFile]
    func download(repo: String,
                  file: RemoteFile,
                  to destination: URL,
                  onProgress: @Sendable @escaping (Int64) -> Void) async throws
}

public enum ModelTransportError: LocalizedError {
    case badResponse(Int)
    case checksumMismatch(String)
    case emptyListing

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "The server responded with status \(code)."
        case .checksumMismatch(let name):
            return "\(name) failed its checksum and was discarded."
        case .emptyListing:
            return "The model folder is empty on the server."
        }
    }
}

public struct HuggingFaceTransport: ModelTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func list(repo: String, path: String) async throws -> [RemoteFile] {
        var components = URLComponents(
            string: "https://huggingface.co/api/models/\(repo)/tree/main/\(path)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelTransportError.badResponse(
                (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let files = entries
            .filter { $0.type == "file" }
            .map { RemoteFile(path: $0.path, size: $0.size, sha256: $0.lfs?.oid) }

        guard !files.isEmpty else { throw ModelTransportError.emptyListing }
        return files
    }

    public func download(repo: String,
                         file: RemoteFile,
                         to destination: URL,
                         onProgress: @Sendable @escaping (Int64) -> Void) async throws {
        let url = URL(string:
            "https://huggingface.co/\(repo)/resolve/main/\(file.path)")!

        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelTransportError.badResponse(
                (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // Written to a sibling temp file and moved into place, so a cancelled
        // or failed download never leaves a half-file that later looks
        // installed.
        let temp = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: temp)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        var hasher = SHA256()
        var chunk = Data()
        chunk.reserveCapacity(1 << 16)
        var written: Int64 = 0

        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= (1 << 16) {
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                written += Int64(chunk.count)
                onProgress(written)
                chunk.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
            }
        }
        if !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            onProgress(written)
        }
        try handle.close()

        if let expected = file.sha256 {
            let actual = hasher.finalize()
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                try? FileManager.default.removeItem(at: temp)
                throw ModelTransportError.checksumMismatch(
                    (file.path as NSString).lastPathComponent)
            }
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: Wire format

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64
        let lfs: LFS?

        struct LFS: Decodable { let oid: String }
    }
}
