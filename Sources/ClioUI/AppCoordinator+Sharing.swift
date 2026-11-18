import AppKit
import ClioCore

/// What of Clio other apps can reach: the meetings, read through the MCP
/// server, and the window, opened by a `clio://` link.
extension AppCoordinator {

    /// The address an MCP client is pointed at.
    public var mcpAddress: String {
        MCPServer.address(port: UInt16(clamping: settingsStore.settings.mcpPort))
    }

    public var isMCPServerRunning: Bool { mcpServer?.isRunning == true }

    /// Starts the server, stops it, or moves it — whatever Settings says
    /// now. Called at launch and whenever the toggle, the port or the
    /// meetings folder changes.
    public func updateMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
        mcpProblem = nil
        let settings = settingsStore.settings
        guard settings.mcpServer else { return }
        let server = MCPServer(folder: MeetingMarkdown.folder(customPath: settings.meetingsFolderPath))
        mcpServer = server
        Task { @MainActor [weak self] in
            do {
                try await server.start(port: UInt16(clamping: settings.mcpPort))
            } catch {
                guard let self, self.mcpServer === server else { return }
                self.mcpServer = nil
                self.mcpProblem = "Port \(settings.mcpPort) could not be opened — something else "
                    + "may be using it: \(error.localizedDescription)"
            }
        }
    }

    /// Follows a link into Clio. False for a link that is not one of ours,
    /// or names a meeting that is not there.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let link = AppLink(url) else { return false }
        switch link {
        case .meeting(let id):
            let folder = MeetingMarkdown.folder(customPath: settingsStore.settings.meetingsFolderPath)
            guard let file = AppLink.file(for: id, in: folder) else {
                showLibrary()
                meetingProblem = "The meeting that link names is not there any more."
                return false
            }
            showLibrary(selecting: .meeting(file))
        case .search(let query):
            showLibrary()
            requestedSearch = query
        case .takeNotes:
            startMeeting()
        }
        return true
    }
}
