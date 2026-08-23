import Foundation

/// Where Scribe keeps things on disk.
///
/// One place, because the About pane has to show these paths to the user and
/// support questions are almost always "where did it put the models".
public enum AppPaths {
    public static let bundleIdentifier =
        Bundle.main.bundleIdentifier ?? "com.bartbak.scribe"

    /// `~/Library/Application Support/<bundle-id>/`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// A model another tool already downloaded is a model we should not download
    /// again. See spec §5.5.
    public static var huggingFaceCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        for url in [supportDirectory, modelsDirectory] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        }
    }
}
