import Foundation
import Synchronization
import Testing
@testable import CompositorPro

private actor LocalAgentNoCredentials {
    static func load() async -> AgentCredentialSnapshot { .init() }
}

@MainActor private final class LocalAgentRunState { var active = true }

private final class LocalAgentToolCancellationGate: Sendable {
    let entered = LocalAgentTestSignal()
    let release = LocalAgentTestSignal()
    let cancelled = Mutex(false)

    func load() async throws -> RuntimeCapabilities.LocalInputs {
        try await withTaskCancellationHandler {
            await entered.open()
            await release.wait()
            try Task.checkCancellation()
            throw ToolError("Fixture released without cancellation.")
        } onCancel: {
            self.cancelled.withLock { $0 = true }
        }
    }
}

@MainActor private final class LocalAgentHTTPClient {
    let endpoint: URL
    private let session = URLSession(configuration: .ephemeral)
    private var sessionID: String?
    private var nextID = 1

    init(endpoint: URL) { self.endpoint = endpoint }

    func connect() async throws {
        _ = try await call("initialize", parameters: [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "local-agent-test", "version": "1"]
        ])
        var request = makeRequest(["jsonrpc": "2.0", "method": "notifications/initialized"])
        request.setValue("http://127.0.0.1:\(endpoint.port!)", forHTTPHeaderField: "Origin")
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
    }

    func call(_ method: String, parameters: [String: Any] = [:]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let (data, response) = try await session.data(for: makeRequest([
            "jsonrpc": "2.0", "id": id, "method": method, "params": parameters
        ]))
        let http = try #require(response as? HTTPURLResponse)
        try #require(http.statusCode == 200)
        if let returned = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = returned }
        let body = String(decoding: data, as: UTF8.self)
        let candidates = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            ? [body]
            : body.components(separatedBy: .newlines).compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        for candidate in candidates {
            let json = try JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any]
            if json?["id"] as? Int == id { return try #require(json?["result"] as? [String: Any]) }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    func tool(_ name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try await call("tools/call", parameters: ["name": name, "arguments": arguments])
    }

    func disconnect() { session.invalidateAndCancel() }

    private func makeRequest(_ object: [String: Any]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "Mcp-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try! JSONSerialization.data(withJSONObject: object)
        return request
    }
}

@Suite("Local agent chat and MCP", .serialized)
@MainActor
struct LocalAgentChatMCPTests {
    private let clipID = "ABCD1234-0000-0000-0000-000000000000"

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheRunCancelsItsToolBeforeProcessCleanupAndDrainsRepeatedStops() async throws {
        let harness = fixture()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let gate = LocalAgentToolCancellationGate()
        let executor = ToolExecutor(editor: harness.editor, capabilityInputLoader: { try await gate.load() })
        let bridge = LocalAgentMCPBridge(executor: executor, conversationID: UUID(), isActive: { true })
        let ready = PackageTestSignal()
        let releaseRun = LocalAgentTestSignal()
        var endpoint: URL?
        let run = Task {
            try await bridge.withConnection {
                endpoint = $0
                ready.signal()
                await releaseRun.wait()
                try Task.checkCancellation()
            }
        }
        await ready.wait()
        let client = LocalAgentHTTPClient(endpoint: try #require(endpoint))
        do {
            try await client.connect()
        } catch {
            run.cancel()
            await releaseRun.open()
            _ = await run.result
            client.disconnect()
            throw error
        }
        let tool = Task {
            let result = try await client.tool("get_capabilities")
            return result["isError"] as? Bool == true
        }
        await gate.entered.wait()

        run.cancel()
        #expect(gate.cancelled.withLock { $0 }, "The tool must be cancelled before the CLI finishes cleanup")
        let firstEntered = PackageTestSignal()
        let secondEntered = PackageTestSignal()
        var firstFinished = false
        var secondFinished = false
        let firstStop = Task {
            firstEntered.signal()
            await bridge.stop()
            firstFinished = true
        }
        await firstEntered.wait()
        let secondStop = Task {
            secondEntered.signal()
            await bridge.stop()
            secondFinished = true
        }
        await secondEntered.wait()
        #expect(!firstFinished && !secondFinished)
        await gate.release.open()
        await releaseRun.open()
        _ = await firstStop.value
        _ = await secondStop.value
        let outcome = await run.result
        if case .failure(let error) = outcome { #expect(error is CancellationError) }
        else { Issue.record("Cancelled run completed successfully") }
        if case .success(let isError) = await tool.result { #expect(isError) }
        client.disconnect()
        await bridge.stop()
        #expect(firstFinished && secondFinished)
        #expect(harness.editor.timeline == before)
        #expect(!undo.canUndo)
    }

    @Test func isolatedHTTPConnectionSharesEditingAndUndoAndRejectsStaleRuns() async throws {
        let harness = fixture()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let state = LocalAgentRunState()
        let clock = LocalAgentProcessTestClock()
        let origin = clock.now
        let activity = LocalAgentActivity(clock: clock)
        let bridge = LocalAgentMCPBridge(executor: harness.executor, conversationID: UUID(),
                                        onActivity: { activity.record() }, isActive: { state.active })
        let client = LocalAgentHTTPClient(endpoint: try await bridge.start())
        do {
            try await client.connect()
            let list = try await client.call("tools/list")
            let tools = try #require(list["tools"] as? [[String: Any]])
            #expect(tools.contains { $0["name"] as? String == "get_timeline" })
            #expect(!tools.contains { $0["name"] as? String == "manage_project" })
            let forbidden = try await client.tool("manage_project", arguments: ["action": "close"])
            #expect(forbidden["isError"] as? Bool == true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)

            clock.advance(to: origin.advanced(by: .seconds(100)))
            let moved = try await client.tool("move_clips", arguments: ["moves": [["clipId": clipID, "toFrame": 60]]])
            #expect(moved["isError"] as? Bool != true)
            #expect(activity.deadline(after: .seconds(7200)) == origin.advanced(by: .seconds(7300)))
            #expect(harness.editor.timeline.tracks[0].clips[0].startFrame == 60)
            let read = try await client.tool("get_timeline")
            #expect(try timelineClips(read).first?["frames"] as? [Int] == [60, 90])
            let undone = try await client.tool("undo")
            #expect(undone["isError"] as? Bool != true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)

            state.active = false
            let stale = try await client.tool("move_clips", arguments: ["moves": [["clipId": clipID, "toFrame": 90]]])
            #expect(stale["isError"] as? Bool == true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        } catch {
            client.disconnect()
            await bridge.stop()
            throw error
        }
        client.disconnect()
        await bridge.stop()
    }

    @Test func inAppAntigravityTurnExecutesOneEditAndKeepsTheResponseInItsChat() async throws {
        let script = try await LocalAgentTestFiles.script(Self.editingCLI)
        let harness = fixture()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let defaultsName = "LocalAgentChatMCPTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let service = AgentService(userDefaults: defaults, credentialLoader: LocalAgentNoCredentials.load,
                                   customKeyLoader: { _ in "" }, sessionLoader: { _ in [] },
                                   localAgentDiscovery: { [.antigravity: script] })
        service.editor = harness.editor
        await service.reloadLocalAgents().value
        service.selectLocalHarness(.antigravity)
        service.messages = [.init(role: .user, blocks: [.text("Move the first clip to frame 60")])]
        let conversation = try #require(service.currentSessionId)
        let run = service.kickOffStream(conversationID: conversation, traceID: UUID(), settings: service.snapshotRunSettings())
        service.newChat()
        await run.value
        do {
            #expect(service.messages.isEmpty)
            let messages = try #require(service.sessions.first { $0.id == conversation }?.messages)
            #expect(messages.last?.blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined() == "Moved the clip.")
            #expect(!service.isStreaming(in: conversation))
            #expect(harness.editor.timeline.tracks[0].clips[0].startFrame == 60)
            #expect(undo.canUndo)
            undo.undo()
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
            let workspaceExists = try await requestWorkspaceStillExists(script)
            #expect(!workspaceExists)
        } catch {
            await service.cancelAndWait()
            try await LocalAgentTestFiles.remove(script)
            throw error
        }
        await service.cancelAndWait()
        try await LocalAgentTestFiles.remove(script)
    }

    private func fixture() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: clipID, start: 0, duration: 30)])]))
    }

    private func timelineClips(_ result: [String: Any]) throws -> [[String: Any]] {
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let timeline = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tracks = try #require(timeline["tracks"] as? [[String: Any]])
        return tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
    }

    @concurrent private func requestWorkspaceStillExists(_ script: URL) async throws -> Bool {
        let path = try String(contentsOf: script.deletingLastPathComponent().appendingPathComponent("request-path"), encoding: .utf8)
        return FileManager.default.fileExists(atPath: path)
    }

    private static let editingCLI = """
    import json, os, sys, urllib.request
    sys.stdin.read()
    with open(os.path.join(os.path.dirname(__file__), 'request-path'), 'w') as f:
        f.write(os.getcwd())
    with open('.agents/mcp_config.json') as f:
        endpoint = json.load(f)['mcpServers']['compositor-pro']['serverUrl']
    session_id = None
    def rpc(body):
        global session_id
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'Mcp-Protocol-Version': '2025-06-18'}
        if session_id:
            headers['Mcp-Session-Id'] = session_id
        request = urllib.request.Request(endpoint, json.dumps(body).encode(), headers)
        with urllib.request.urlopen(request, timeout=5) as response:
            session_id = response.headers.get('Mcp-Session-Id') or session_id
            text = response.read().decode()
        if not text:
            return {}
        if not text.lstrip().startswith('{'):
            text = next(line[5:].strip() for line in text.splitlines() if line.startswith('data:') and line[5:].strip() and json.loads(line[5:]).get('id') == body.get('id'))
        return json.loads(text)
    rpc({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'fixture-CLI','version':'1'}}})
    rpc({'jsonrpc':'2.0','method':'notifications/initialized'})
    result = rpc({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'move_clips','arguments':{'moves':[{'clipId':'ABCD1234-0000-0000-0000-000000000000','toFrame':60}]}}})
    assert not result.get('error') and not result['result'].get('isError'), result
    print(json.dumps({'event':'result','result':{'status':'SUCCESS','response':'Moved the clip.'}}), flush=True)
    """
}
