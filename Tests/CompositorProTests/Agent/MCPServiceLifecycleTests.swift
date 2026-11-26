import AppKit
import Foundation
import Testing

@testable import CompositorPro

private actor MCPStartupGateListener: MCPServiceListener {
    private var startup: CheckedContinuation<Void, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var isListening = false

    func start() async throws {
        starts += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await withCheckedThrowingContinuation { startup = $0 }
        isListening = true
    }

    func stop() async {
        stops += 1
        isListening = false
        stopWaiters.forEach { $0.resume() }
        stopWaiters.removeAll()
    }

    func waitForStart() async {
        if starts > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForStop() async {
        if stops > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func finishStartup() {
        startup?.resume()
        startup = nil
    }
}

@Suite("MCP service lifecycle", .serialized)
@MainActor
struct MCPServiceLifecycleTests {
    @Test func stopDrainsLateStartupAndCoalescesRepeatedRequests() async throws {
        let listener = MCPStartupGateListener()
        let service = MCPService(projectProvider: { nil }, listener: listener)
        let startup = try #require(service.start())
        await listener.waitForStart()
        #expect(service.isStarting)
        #expect(service.start() != nil)
        #expect(await listener.starts == 1)

        let firstStop = Task { await service.stop() }
        await listener.waitForStop()
        #expect(service.state == .stopping)
        #expect(!service.isRunning)
        #expect(service.start() == nil)
        var secondStop: Task<Void, Never>?
        await withCheckedContinuation { entered in
            secondStop = Task { @MainActor in
                entered.resume()
                await service.stop()
            }
        }

        await listener.finishStartup()
        await startup.value
        await firstStop.value
        await secondStop?.value
        #expect(service.state == .stopped)
        #expect(!service.isRunning)
        #expect(service.startupError == nil)
        #expect(!(await listener.isListening))
        #expect(await listener.starts == 1)
        #expect(await listener.stops == 2)
    }

    @Test func stopBeforeStartupAdmissionDoesNotStartListener() async throws {
        let listener = MCPStartupGateListener()
        let service = MCPService(projectProvider: { nil }, listener: listener)
        let startup = try #require(service.start())

        await service.stop()
        await startup.value
        #expect(service.state == .stopped)
        #expect(await listener.starts == 0)
        #expect(!(await listener.isListening))
    }

    @Test func retryAfterOccupiedPortSupportsHTTPDiscoveryAndReadback() async throws {
        let port = UInt16.random(in: 49_500...64_000)
        let defaultsName = "MCPServiceLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let project = VideoProject()
        project.editorViewModel.timeline.name = "MCP Retry Fixture"
        NSDocumentController.shared.addDocument(project)
        defer {
            NSDocumentController.shared.removeDocument(project)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let blocker = MCPService(projectProvider: { nil }, port: port, userDefaults: defaults)
        let service = MCPService(projectProvider: { project }, port: port, userDefaults: defaults)
        let session = URLSession(configuration: .ephemeral)

        do {
            await blocker.start()?.value
            try #require(blocker.isRunning)
            await service.start()?.value
            #expect(!service.isRunning)
            #expect(service.startupError != nil)

            await blocker.stop()
            await service.start()?.value
            #expect(service.isRunning)
            #expect(service.startupError == nil)

            let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
            let initialize = request(
                endpoint,
                body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lifecycle-test","version":"1"}}}"#
            )
            let (initializeData, initializeResponse) = try await session.data(for: initialize)
            let initializeHTTP = try #require(initializeResponse as? HTTPURLResponse)
            #expect(initializeHTTP.statusCode == 200)
            let sessionID = try #require(initializeHTTP.value(forHTTPHeaderField: "Mcp-Session-Id"))
            let initialized = try responseObject(initializeData, expectedID: 1)
            #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
            let serverInfo = try #require((initialized["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
            #expect(serverInfo["name"] as? String == "compositor-pro")

            let (notificationData, notificationResponse) = try await session.data(for: request(
                endpoint, sessionID: sessionID,
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            ))
            #expect((notificationResponse as? HTTPURLResponse)?.statusCode == 202)
            #expect(notificationData.isEmpty)

            let (listData, listResponse) = try await session.data(for: request(
                endpoint, sessionID: sessionID,
                body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            ))
            #expect((listResponse as? HTTPURLResponse)?.statusCode == 200)
            let listed = try responseObject(listData, expectedID: 2)
            let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            #expect(tools.contains { $0["name"] as? String == "get_timeline" })

            let (callData, callResponse) = try await session.data(for: request(
                endpoint, sessionID: sessionID,
                body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_timeline","arguments":{}}}"#
            ))
            #expect((callResponse as? HTTPURLResponse)?.statusCode == 200)
            let called = try responseObject(callData, expectedID: 3)
            let result = try #require(called["result"] as? [String: Any])
            #expect(result["isError"] as? Bool != true)
            let content = try #require(result["content"] as? [[String: Any]])
            let timelineText = try #require(content.first?["text"] as? String)
            let timeline = try #require(JSONSerialization.jsonObject(with: Data(timelineText.utf8)) as? [String: Any])
            #expect(timeline["name"] as? String == "MCP Retry Fixture")
            #expect(project.editorViewModel.timeline.name == "MCP Retry Fixture")

            session.invalidateAndCancel()
            await service.stop()
            #expect(service.state == .stopped)
            let disconnectedSession = URLSession(configuration: .ephemeral)
            do {
                _ = try await disconnectedSession.data(for: initialize)
                Issue.record("A new HTTP connection succeeded after MCP shutdown")
            } catch {
                #expect(error is URLError)
            }
            disconnectedSession.invalidateAndCancel()
        } catch {
            session.invalidateAndCancel()
            await service.stop()
            await blocker.stop()
            throw error
        }
        session.invalidateAndCancel()
        await service.stop()
        await blocker.stop()
    }

    private func request(_ url: URL, sessionID: String? = nil, body: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = Data(body.utf8)
        return request
    }

    private func responseObject(_ data: Data, expectedID: Int) throws -> [String: Any] {
        let body = String(decoding: data, as: UTF8.self)
        let payload: Data
        if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            payload = data
        } else {
            let messages = body.components(separatedBy: .newlines).compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            payload = Data(try #require(messages.first).utf8)
        }
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        try #require(object["id"] as? Int == expectedID)
        #expect(object["jsonrpc"] as? String == "2.0")
        return object
    }
}
