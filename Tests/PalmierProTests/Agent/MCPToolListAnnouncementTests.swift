import Foundation
import MCP
import Testing

@testable import PalmierPro

/// Each stateful session announces tools/list_changed exactly once, after its
/// standalone GET stream attaches, so proxied clients refetch across app restarts.
struct MCPToolListAnnouncementTests {

    @Test func sessionAnnouncesToolListChangedOnceOnGetStreamAttach() async throws {
        let port = UInt16.random(in: 49_500...64_000)
        let server = MCPHTTPServer(port: port) {
            let server = Server(
                name: "test",
                version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: true))
            )
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
            return MCPServerInstance(server: server) { _ in }
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let base = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var initialize = URLRequest(url: base)
        initialize.httpMethod = "POST"
        initialize.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initialize.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        initialize.httpBody = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
                .utf8)

        let (_, initResponse) = try await URLSession.shared.data(for: initialize)
        let sessionID = try #require(
            (initResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"))

        var get = URLRequest(url: base)
        get.httpMethod = "GET"
        get.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        get.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        get.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")

        let (stream, getResponse) = try await URLSession.shared.bytes(for: get)
        #expect((getResponse as? HTTPURLResponse)?.statusCode == 200)

        let announced = try await firstEvent(
            in: stream, containing: "notifications/tools/list_changed", within: .seconds(10))
        #expect(announced == true)

        // Announce is once per session: no duplicate follows on the same stream,
        // even when further requests touch the session.
        var list = URLRequest(url: base)
        list.httpMethod = "POST"
        list.setValue("application/json", forHTTPHeaderField: "Content-Type")
        list.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        list.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        list.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        list.httpBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        _ = try await URLSession.shared.data(for: list)

        let announcedAgain = try await firstEvent(
            in: stream, containing: "notifications/tools/list_changed", within: .seconds(2))
        #expect(announcedAgain == nil)
    }

    /// True when an SSE line containing `needle` arrives; nil on stream end or timeout.
    private func firstEvent(
        in stream: URLSession.AsyncBytes,
        containing needle: String,
        within timeout: Duration
    ) async throws -> Bool? {
        try await withThrowingTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for try await line in stream.lines where line.contains(needle) { return true }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
