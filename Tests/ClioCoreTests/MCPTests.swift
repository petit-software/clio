import Testing
import Foundation
@testable import ClioCore

@Suite("MCP server")
struct MCPTests {
    /// A folder with two meetings in it: one recorded, with voices; one written by hand.
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clio-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sync = MeetingRecord(title: "Weekly sync", startDate: Date(timeIntervalSince1970: 1_790_000_000))
        sync.endDate = sync.startDate.addingTimeInterval(1_800)
        sync.attendees = [MeetingAttendee(name: "Ana Ruiz", email: "ana@example.com")]
        sync.notes = "- pricing? <!--02:10-->"
        sync.summary = "### Pricing\n- Stays as it is."
        sync.add(MeetingLine(speaker: .me, start: 5, end: 8, text: "Shall we talk about pricing?"))
        sync.add(MeetingLine(speaker: .others, start: 30, end: 34, text: "It stays as it is.", voice: 1))
        sync.name(voice: 1, as: "Ana Ruiz", confirmed: true)
        try MeetingMarkdown.write(sync, to: folder)
        var notes = MeetingRecord(title: "Offsite ideas", startDate: Date(timeIntervalSince1970: 1_790_200_000))
        notes.notes = "- a cabin"
        try MeetingMarkdown.write(notes, to: folder)
        return folder
    }

    private func ask(_ method: String, _ params: [String: Any] = [:], id: Any? = 1,
                     tools: MeetingTools) throws -> [String: Any]? {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        let body = try JSONSerialization.data(withJSONObject: message)
        guard let answer = MCPProtocol.handle(body, tools: tools) else { return nil }
        return try JSONSerialization.jsonObject(with: answer) as? [String: Any]
    }

    /// The text of a tool's answer, and whether it was an error.
    private func call(_ name: String, _ arguments: [String: Any], tools: MeetingTools) throws -> (text: String, isError: Bool) {
        let answer = try #require(try ask("tools/call", ["name": name, "arguments": arguments], tools: tools))
        let result = try #require(answer["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    @Test("It introduces itself, lists three tools, and says nothing back to a notification")
    func handshake() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MeetingTools(folder: folder)

        let hello = try #require(try ask("initialize", ["protocolVersion": "2025-03-26"], tools: tools))
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")           // the one asked for
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "clio")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        let unknown = try #require(try ask("initialize", ["protocolVersion": "1999-01-01"], tools: tools))
        #expect((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == MCPProtocol.versions[0])

        #expect(try ask("notifications/initialized", id: nil, tools: tools) == nil)

        let list = try #require(try ask("tools/list", tools: tools))
        let listed = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(listed.compactMap { $0["name"] as? String }
                == ["clio_query_meetings", "clio_get_meeting", "clio_get_transcript"])
        #expect(listed.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let missing = try #require(try ask("resources/list", id: "abc", tools: tools))
        #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(missing["id"] as? String == "abc")
        let garbage = try #require(MCPProtocol.handle(Data("not json".utf8), tools: tools))
        #expect(String(decoding: garbage, as: UTF8.self).contains("-32700"))
    }

    @Test("Meetings are found by words, people and dates, read by id, and nothing but read")
    func tools() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MeetingTools(folder: folder)
        func found(_ arguments: [String: Any]) throws -> [String] {
            let answer = try call("clio_query_meetings", arguments, tools: tools)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(answer.text.utf8)) as? [String: Any])
            return ((json["meetings"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
        }
        #expect(try found([:]) == ["Offsite ideas", "Weekly sync"])              // newest first
        #expect(try found(["query": "pricing stays"]) == ["Weekly sync"])
        #expect(try found(["person": "ana@example"]) == ["Weekly sync"])
        #expect(try found(["query": "cabin"]) == ["Offsite ideas"])
        // The sync is on 21 September 2026, the offsite ideas two days later.
        #expect(try found(["from": "2026-09-21"]).count == 2)
        #expect(try found(["from": "2026-09-22"]) == ["Offsite ideas"])
        #expect(try found(["to": "2026-09-21"]) == ["Weekly sync"])
        #expect(try found(["limit": 1]).count == 1)
        #expect(try call("clio_query_meetings", ["from": "last week"], tools: tools).isError)

        let all = try call("clio_query_meetings", [:], tools: tools)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(all.text.utf8)) as? [String: Any])
        let sync = try #require((json["meetings"] as? [[String: Any]])?.last)
        let id = try #require(sync["id"] as? String)
        #expect(AppLink(URL(string: try #require(sync["link"] as? String))!) == .meeting(id: id))

        let meeting = try call("clio_get_meeting", ["id": id], tools: tools)
        #expect(!meeting.isError)
        #expect(meeting.text.contains("- pricing?") && !meeting.text.contains("<!--"))   // notes as words
        #expect(meeting.text.contains("Stays as it is") && meeting.text.contains("ana@example.com"))
        #expect(!meeting.text.contains("Shall we talk"))                                  // not the transcript

        let transcript = try call("clio_get_transcript", ["id": id], tools: tools)
        #expect(transcript.text.contains("[00:05] Me: Shall we talk about pricing?"))
        #expect(transcript.text.contains("[00:30] Ana Ruiz: It stays as it is."))

        // An id is a name in the folder, never a path out of it.
        #expect(try call("clio_get_meeting", ["id": "../../etc/passwd"], tools: tools).isError)
        #expect(try call("clio_get_meeting", [:], tools: tools).isError)
        #expect(try call("clio_delete_meeting", ["id": id], tools: tools).isError)
        // And the files are as they were.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test("Links into Clio read back as what they were made from; anything else is no link")
    func links() {
        for link in [AppLink.meeting(id: "2026-11-18 09.00 Weekly sync & more"), .search(query: "pricing page"), .takeNotes] {
            #expect(AppLink(link.url) == link)
        }
        #expect(AppLink.search(query: "a b").url.absoluteString == "clio://search?q=a%20b")
        #expect(AppLink(URL(string: "clio://meeting")!) == nil)
        #expect(AppLink(URL(string: "clio://delete?id=x")!) == nil)
        #expect(AppLink(URL(string: "https://meeting?id=x")!) == nil)
    }

    @Test("A browser page that is not on this Mac is refused; an app, or a page on it, is not")
    func origins() {
        #expect(MCPServer.isLocal(origin: nil))                       // not a browser
        #expect(MCPServer.isLocal(origin: "http://localhost:3000"))
        #expect(MCPServer.isLocal(origin: "http://127.0.0.1:8765"))
        #expect(!MCPServer.isLocal(origin: "https://example.com"))
        #expect(!MCPServer.isLocal(origin: "null"))                   // a sandboxed page
        #expect(!MCPServer.isLocal(origin: "http://127.0.0.1.example.com"))
    }

    @Test("Over HTTP on the loopback address: a question is answered, a page elsewhere is not, and only POST /mcp is heard")
    func http() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = MCPServer(folder: folder)
        try await server.start(port: 0)                               // whatever is free
        defer { server.stop() }
        #expect(server.isRunning && server.port != 0)
        let url = try #require(URL(string: MCPServer.address(port: server.port)))

        func post(_ body: [String: Any], origin: String? = nil, to target: URL? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: target ?? url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/list"]
        let (status, data) = try await post(list)
        #expect(status == 200)
        let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(answer["id"] as? Int == 7)
        #expect(((answer["result"] as? [String: Any])?["tools"] as? [Any])?.count == 3)

        #expect(try await post(["jsonrpc": "2.0", "method": "notifications/initialized"]).0 == 202)
        #expect(try await post(list, origin: "https://example.com").0 == 403)
        #expect(try await post(list, to: url.deletingLastPathComponent().appendingPathComponent("other")).0 == 404)
        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        #expect(((try await URLSession.shared.data(for: get)).1 as? HTTPURLResponse)?.statusCode == 405)

        server.stop()
        #expect(!server.isRunning)
    }
}
