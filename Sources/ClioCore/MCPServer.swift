import Foundation
import Network

/// The Model Context Protocol, as much of it as serving three read-only
/// tools needs: JSON-RPC 2.0 requests in, responses out.
///
/// The messages only — no socket — so every one of them can be tested as a
/// value. `MCPServer` puts HTTP round it.
public enum MCPProtocol {
    /// The revisions spoken. A client that asks for one of these gets it;
    /// one that asks for anything else is offered the newest.
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func version() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// The answer to one message; nil for a notification, which has none.
    public static func handle(_ body: Data, tools: MeetingTools) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return error(id: NSNull(), code: -32700, message: "Parse error")
        }
        // No id: a notification. Nothing is said back, whatever it was.
        guard let id = message["id"], !(id is NSNull) else { return nil }
        guard let method = message["method"] as? String else {
            return error(id: id, code: -32600, message: "Invalid request")
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return result(id: id, [
                "protocolVersion": asked.flatMap { versions.contains($0) ? $0 : nil } ?? versions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "clio", "title": "Clio", "version": version()],
                "instructions": "Meetings recorded and noted in Clio on this Mac: find them, read their notes "
                    + "and summaries, read their transcripts. Read-only.",
            ])
        case "ping":
            return result(id: id, [String: Any]())
        case "tools/list":
            return result(id: id, ["tools": MeetingTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "tools/call needs a name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try tools.call(name, arguments: arguments)
                return result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch let failure as MeetingTools.ToolError {
                // What a model can read and act on, not a protocol error.
                return result(id: id, ["content": [["type": "text", "text": failure.message]], "isError": true])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": error.localizedDescription]],
                                       "isError": true])
            }
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: Any, _ result: [String: Any]) -> Data {
        data(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any, code: Int, message: String) -> Data {
        data(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }
}

/// The MCP server: HTTP on this Mac's loopback address and nowhere else,
/// answering `POST /mcp`.
///
/// Off unless Settings turns it on. Bound to 127.0.0.1, so nothing off this
/// Mac can reach it; and a request that says it comes from a web page that
/// is not on this Mac is refused, so a site open in a browser cannot ask
/// through the browser either.
public final class MCPServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 8765
    public static let path = "/mcp"

    private let tools: MeetingTools
    private let queue = DispatchQueue(label: "com.bartbak.clio.mcp")
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0

    public init(folder: URL) {
        tools = MeetingTools(folder: folder)
    }

    deinit { stop() }

    public var isRunning: Bool { listener != nil }

    /// "http://127.0.0.1:8765/mcp" — what a client is pointed at.
    public static func address(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    /// Starts listening. Throws when the port cannot be had — in use by
    /// something else, most likely.
    public func start(port: UInt16 = MCPServer.defaultPort) async throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // Ready, or failed: one of the two, once.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Only ever touched on `queue`, where the handler runs.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume()
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    once.done = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.port = listener.port?.rawValue ?? port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    /// The most a request may be: these are small questions.
    static let requestLimit = 1_000_000

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                self.respond(to: request, on: connection)
            } else if error != nil || done || buffer.count > Self.requestLimit {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    /// A whole HTTP request: the line, the headers, and as much body as
    /// `Content-Length` says. Nil until all of it has arrived.
    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { return nil }
            method = String(first[0])
            path = String(first[1])
            headers = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let start = end.upperBound
            guard data.count - start >= length else { return nil }
            body = data.subdata(in: start..<(start + length))
        }
    }

    /// Whether a request's `Origin` — which a browser sends and other
    /// clients mostly do not — is this Mac. Without the check, a web page
    /// could have the browser ask on its behalf.
    static func isLocal(origin: String?) -> Bool {
        guard let origin, !origin.isEmpty, origin != "null" else { return origin != "null" }
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }

    func response(to request: Request) -> (status: String, body: Data) {
        guard Self.isLocal(origin: request.headers["origin"]) else {
            return ("403 Forbidden", Data("Clio answers only to apps on this Mac.".utf8))
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == Self.path else { return ("404 Not Found", Data()) }
        guard request.method == "POST" else {
            // No stream to open, no session to end: only questions.
            return ("405 Method Not Allowed", Data())
        }
        guard let answer = MCPProtocol.handle(request.body, tools: tools) else {
            return ("202 Accepted", Data())
        }
        return ("200 OK", answer)
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let (status, body) = response(to: request)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: \(status.hasPrefix("200") ? "application/json" : "text/plain; charset=utf-8")\r\n" }
        if status.hasPrefix("405") { head += "Allow: POST\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
