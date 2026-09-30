import Foundation
import Network
import Testing
@testable import PalmierPro

/// Drives `BYOKClient` against a loopback server so the whole custom path — URL, headers,
/// request body, and SSE decoding — is proven without the settings UI.
@Suite("Custom endpoint transport")
struct CustomEndpointTransportTests {

    @Test func keylessLoopbackEndpointStreamsFromChatCompletions() async throws {
        let server = try await LoopbackServer { _ in Self.sseResponse }
        defer { server.cancel() }
        let endpoint = try #require(CustomModelStore.normalizedBaseURL(server.baseURL))
        let client = Self.client(modelID: "qwen3-coder:30b", endpoint: endpoint, apiKey: "")

        var events: [AgentStreamEvent] = []
        for try await event in client.stream(
            system: "Instructions",
            tools: [AgentToolSchema(name: "get_timeline", description: "Read", inputSchema: ["type": "object"])],
            messages: [AgentRequestMessage(role: .user, content: [.content(.text("Cut the intro"))])],
            context: Self.context
        ) {
            events.append(event)
        }

        let request = try #require(server.request)
        #expect(request.hasPrefix("POST /v1/chat/completions "))
        // No key means no Authorization header — that is the point of loopback support.
        #expect(!request.lowercased().contains("authorization:"))
        #expect(request.contains("\"model\":\"qwen3-coder:30b\""))
        #expect(request.contains("\"stream\":true"))
        #expect(request.contains("get_timeline"))

        #expect(events.contains(.textDelta("Hello")))
        #expect(events.contains(.toolUseComplete(
            id: "call_1", name: "get_timeline", inputJSON: "{\"limit\":5}")))
        #expect(events.contains(.messageStop(stopReason: .toolUse)))
    }

    @Test func keyedLoopbackEndpointSendsBearerToken() async throws {
        let server = try await LoopbackServer { _ in
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: [DONE]\n\n"
        }
        defer { server.cancel() }
        let endpoint = try #require(CustomModelStore.normalizedBaseURL(server.baseURL))
        let client = Self.client(modelID: "m", endpoint: endpoint, apiKey: "sk-local")

        for try await _ in client.stream(system: "", tools: [], messages: [], context: Self.context) {}

        #expect(try #require(server.request).lowercased().contains("authorization: bearer sk-local"))
    }

    @Test func remoteEndpointRefusesToStreamWithoutAKey() async {
        let client = Self.client(
            modelID: "m",
            endpoint: URL(string: "https://api.example.com/v1")!,
            apiKey: ""
        )
        do {
            for try await _ in client.stream(system: "", tools: [], messages: [], context: Self.context) {}
            Issue.record("Expected a missing-credential failure")
        } catch let error as AgentClientTransportError {
            guard case .missingAPIKey(.custom) = error else {
                Issue.record("Expected missingAPIKey, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected a transport error, got \(error)")
        }
    }

    @Test func serverErrorsSurfaceStatusAndBody() async throws {
        let server = try await LoopbackServer { _ in
            "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\":\"no such model\"}"
        }
        defer { server.cancel() }
        let endpoint = try #require(CustomModelStore.normalizedBaseURL(server.baseURL))
        let client = Self.client(modelID: "missing", endpoint: endpoint, apiKey: "")

        do {
            for try await _ in client.stream(system: "", tools: [], messages: [], context: Self.context) {}
            Issue.record("Expected an HTTP failure")
        } catch let error as AgentClientTransportError {
            guard case .httpError(let provider, let status, let body) = error else {
                Issue.record("Expected httpError, got \(error)")
                return
            }
            #expect(provider == .custom)
            #expect(status == 404)
            #expect(body.contains("no such model"))
        } catch {
            Issue.record("Expected an httpError, got \(error)")
        }
    }

    // MARK: - Fixtures

    private static func client(modelID: String, endpoint: URL, apiKey: String) -> BYOKClient {
        BYOKClient(
            apiKey: apiKey,
            settings: AgentRunSettings(
                model: .custom,
                reasoningEffort: .none,
                custom: CustomAgentModel(baseURL: endpoint, modelID: modelID)
            )
        )
    }

    private static let context = AgentRequestContext(
        conversationID: UUID(), traceID: UUID(), spanID: UUID(),
        inputMessageID: UUID(), outputMessageID: UUID(), projectID: nil
    )

    private static let sseResponse = """
    HTTP/1.1 200 OK\r
    Content-Type: text/event-stream\r
    \r
    data: {"choices":[{"delta":{"content":"Hello"}}]}\n
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_timeline","arguments":"{\\"limit\\":5}"}}]}}]}\n
    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n
    data: [DONE]\n
    """
}

/// Replays a capture of the provider's real SSE through the actual client, so a framing or
/// line-splitting fault between socket and parser fails here instead of being inferred from
/// a log line. Shape copied from a live OpenRouter stream for this model.
@Suite("Custom endpoint provider stream replay")
struct CustomEndpointStreamReplayTests {

    @Test func capturedProviderStreamYieldsToolCallsAndToolUseStop() async throws {
        let server = try await LoopbackServer { _ in Self.providerStream }
        defer { server.cancel() }
        let endpoint = try #require(CustomModelStore.normalizedBaseURL(server.baseURL))
        let client = BYOKClient(
            apiKey: "",
            settings: AgentRunSettings(
                model: .custom,
                reasoningEffort: .none,
                custom: CustomAgentModel(baseURL: endpoint, modelID: "stealth/space-bunny-alpha")
            )
        )

        let prompt = AgentRequestMessage(role: .user, content: [.content(.text("Add captions"))])
        var events: [AgentStreamEvent] = []
        for try await event in client.stream(
            system: "s", tools: [], messages: [prompt], context: .replay
        ) {
            events.append(event)
        }

        #expect(events.contains(.textDelta("I'll start by reviewing")))
        let names = events.compactMap { event -> String? in
            guard case .toolUseComplete(_, let name, _) = event else { return nil }
            return name
        }
        #expect(names.contains("get_timeline"))
        #expect(names.contains("get_transcript"))
        #expect(events.contains(.messageStop(stopReason: .toolUse)))
    }

    private static let providerStream = """
    HTTP/1.1 200 OK\r
    Content-Type: text/event-stream\r
    \r
    data: {"id":"gen-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"I'll start by reviewing"},"finish_reason":null}]}\n
    data: {"id":"gen-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" the timeline and transcript."},"finish_reason":null}]}\n
    data: {"id":"gen-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_timeline","arguments":""}}]},"finish_reason":null}]}\n
    data: {"id":"gen-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]},"finish_reason":null}]}\n
    data: {"id":"gen-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"get_transcript","arguments":""}}]},"finish_reason":null}]}\n
    data: {"id":"gen-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n
    data: [DONE]\n
    """
}

extension AgentRequestContext {
    static var replay: AgentRequestContext {
        AgentRequestContext(
            conversationID: UUID(), traceID: UUID(), spanID: UUID(),
            inputMessageID: UUID(), outputMessageID: UUID(), projectID: nil
        )
    }
}

/// One-shot HTTP/1.1 loopback server. `BYOKClient` sends `Content-Length` framing, so reading
/// the head plus that many body bytes is the whole request; the handler sees it raw.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let received: Locked<String?>
    private let port: UInt16
    private static let separator = Data("\r\n\r\n".utf8)

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    var request: String? { received.value }

    init(
        response: @escaping @Sendable (String) -> String,
        receivedRequest: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let received = Locked<String?>(nil)
        self.received = received
        let ready = ReadinessGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.open(listener.port?.rawValue ?? 0)
            case .failed: ready.open(0)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.readRequest(on: connection) { raw in
                received.value = raw
                receivedRequest?(raw)
                connection.send(
                    content: Data(response(raw).utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        listener.start(queue: .global())
        let bound = await ready.wait()
        guard bound != 0 else { throw LoopbackServerError.failedToBind }
        self.port = bound
    }

    func cancel() { listener.cancel() }

    private static func readRequest(
        on connection: NWConnection,
        onComplete: @escaping @Sendable (String) -> Void
    ) {
        let buffer = Locked(Data())
        @Sendable func step() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, ended, error in
                if let data { buffer.value.append(data) }
                if requestIsComplete(buffer.value, ended: ended, error: error) {
                    return onComplete(String(decoding: buffer.value, as: UTF8.self))
                }
                step()
            }
        }
        step()
    }

    private static func requestIsComplete(_ buffer: Data, ended: Bool, error: NWError?) -> Bool {
        if error != nil || ended { return true }
        guard let headEnd = buffer.range(of: separator) else { return false }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        let expected = head
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? "") }
        return buffer.count - headEnd.upperBound >= (expected ?? 0)
    }

    enum LoopbackServerError: Error { case failedToBind }
}

private final class ReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Never>?
    private var opened = false

    func open(_ port: UInt16) {
        lock.lock()
        guard !opened else {
            lock.unlock()
            return
        }
        opened = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: port)
    }

    func wait() async -> UInt16 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                return continuation.resume(returning: 0)
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
