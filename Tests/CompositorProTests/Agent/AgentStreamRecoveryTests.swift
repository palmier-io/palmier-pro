import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Agent stream recovery")
@MainActor
struct AgentStreamRecoveryTests {
    @Test func emptyCompletedResponseSurfacesFailure() async throws {
        try await withRuntime { service, editor, _, undo in
            let client = RecoveryClient([.init(events: [.messageStop(stopReason: .endTurn)])])
            await start(service, client: client).value

            #expect(service.streamError != nil)
            #expect(!service.isStreaming)
            #expect(service.messages.count == 1)
            #expect(editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func timeoutRetryRemainsVisibleWhileAwaitingTheNextResponse() async throws {
        try await withRuntime { service, _, _, _ in
            let recorder = RequestProgressRecorder()
            let client = RecoveryClient([.init(failure: URLError(.timedOut)), .finished], onRequest: {
                recorder.progress.append(service.requestProgress)
            })
            let run = start(service, client: client)
            #expect(service.requestProgress != nil)
            await run.value

            try #require(recorder.progress.count == 2)
            #expect(recorder.progress[0]?.phase == .waitingForResponse)
            #expect(recorder.progress[0]?.retry == nil)
            #expect(recorder.progress[1]?.phase == .waitingForResponse)
            #expect(recorder.progress[1]?.retry == .timeout(attempt: 1, limit: 2))
            #expect(service.requestProgress == nil)
        }
    }

    @Test func repeatedOutputTruncationStopsWithAReason() async throws {
        try await withRuntime { service, editor, _, undo in
            let response = RecoveryClient.Response(events: [.textDelta("Partial"), .messageStop(stopReason: .maxTokens)])
            let client = RecoveryClient(Array(repeating: response, count: 3))
            await start(service, client: client).value

            #expect(await client.requests.count == 3)
            #expect(service.streamError != nil)
            #expect(!service.isStreaming)
            #expect(service.requestProgress == nil)
            #expect(editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: TimeoutFailure.allCases)
    func timeoutRetriesTheSameInputWithANewResponse(_ failure: TimeoutFailure) async throws {
        try await withRuntime { service, _, _, _ in
            let client = RecoveryClient([.init(failure: failure.error), .finished])
            await start(service, client: client).value

            let requests = await client.requests
            try #require(requests.count == 2)
            #expect(requests[0].context.inputMessageID == requests[1].context.inputMessageID)
            #expect(requests[0].context.traceID == requests[1].context.traceID)
            #expect(requests[0].context.outputMessageID != requests[1].context.outputMessageID)
            #expect(requests[1].messages.count == 1)
            #expect(service.messages.count == 2)
            #expect(service.streamError == nil)
            #expect(!service.isStreaming)
        }
    }

    @Test func retryDiscardsUnexecutedCallsAndPreservesCompletedEditAndUndo() async throws {
        try await withRuntime { service, editor, mcp, undo in
            let client = RecoveryClient([
                .addClip,
                .init(events: [
                    .reasoningSummaryDelta("Unfinished decision"),
                    .textDelta("Discarded attempt"),
                    .toolUseComplete(id: "unexecuted", name: "add_clips", inputJSON: RecoveryClient.clipInput),
                ], failure: URLError(.timedOut)),
                .finished,
            ])
            await start(service, client: client).value

            let requests = await client.requests
            try #require(requests.count == 3)
            let retryBlocks = requests[2].messages.flatMap(\.content)
            #expect(retryBlocks.contains {
                if case .content(.toolResult(let id, _, false)) = $0 { return id == "completed_edit" }
                return false
            })
            #expect(!retryBlocks.contains {
                if case .content(.toolUse(let id, _, _)) = $0 { return id == "unexecuted" }
                if case .content(.text(let text)) = $0 { return text == "Discarded attempt" }
                if case .content(.openAIReasoning(let summary, _, _, _, _)) = $0 { return summary == "Unfinished decision" }
                return false
            })
            let read = try await mcp.callTool(name: "get_timeline")
            #expect(read.isError != true)
            let payload = try json(read)
            let tracks = try #require(payload["tracks"] as? [[String: Any]])
            let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
            #expect(clips.count == 1)
            #expect(clips.first?["frames"] as? [Int] == [0, 60])
            #expect(editor.timeline.tracks.flatMap(\.clips).count == 1)
            #expect(service.streamError == nil)
            #expect(service.sessions.first?.messages.map(\.id) == service.messages.map(\.id))

            let undone = try await mcp.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func repeatedTimeoutsStopWithoutMutationsOrOrphanCalls() async throws {
        try await withRuntime { service, editor, _, undo in
            let failed = RecoveryClient.Response(events: [
                .toolUseComplete(id: "unexecuted", name: "add_clips", inputJSON: RecoveryClient.clipInput),
            ], failure: URLError(.timedOut))
            let client = RecoveryClient(Array(repeating: failed, count: 3))
            await start(service, client: client).value

            #expect(await client.requests.count == 3)
            #expect(service.streamError != nil)
            #expect(!service.isStreaming)
            #expect(service.messages.count == 1)
            #expect(editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func successfulToolResponseResetsTimeoutRetryBudget() async throws {
        try await withRuntime { service, editor, _, _ in
            let failed = RecoveryClient.Response(failure: URLError(.timedOut))
            let client = RecoveryClient([failed, failed, .addClip, failed, failed, .finished])
            await start(service, client: client).value

            #expect(await client.requests.count == 6)
            #expect(service.streamError == nil)
            #expect(editor.timeline.tracks.flatMap(\.clips).count == 1)
        }
    }

    @Test(arguments: NonTimeoutFailure.allCases)
    func nonTimeoutFailuresDoNotRetry(_ failure: NonTimeoutFailure) async throws {
        try await withRuntime { service, _, _, _ in
            let client = RecoveryClient([.init(failure: failure.error)])
            await start(service, client: client).value

            #expect(await client.requests.count == 1)
            #expect((service.streamError == nil) == failure.isCancellation)
            #expect(!service.isStreaming)
        }
    }

    @Test(arguments: LifecycleChange.allCases)
    func cancellationDuringTimeoutCleanupPreventsRetry(_ change: LifecycleChange) async throws {
        try await withRuntime { service, editor, _, undo in
            let original = try #require(service.currentSessionId)
            let client = RecoveryClient([
                .init(events: [.textDelta("Discarded attempt")], failure: URLError(.timedOut)), .finished,
            ], heldCleanupIndex: 0)
            let run = start(service, client: client)
            await client.cleanupEntered.wait()
            await client.cleanupCancelled.wait()
            var drain: Task<Void, Never>?
            switch change {
            case .cancel: service.cancel()
            case .sessionSwitch: service.newChat()
            case .editorChange: service.editor = nil
            case .close:
                service.cancel()
                drain = Task { await service.cancelAndWait() }
            }
            let selected = service.currentSessionId
            #expect(!service.isStreaming)
            #expect(service.requestProgress == nil)
            #expect(await client.requests.count == 1)
            await client.cleanupRelease.open()
            await run.value
            if let drain { await drain.value }

            #expect(await client.requests.count == 1)
            #expect(service.currentSessionId == selected)
            #expect(service.streamError == nil)
            #expect(service.sessions.first { $0.id == original }?.messages.count == 1)
            if change == .sessionSwitch { #expect(service.messages.isEmpty) }
            #expect(editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!undo.canUndo)
        }
    }

    enum TimeoutFailure: CaseIterable {
        case url, nsURL, requestHTTP, gatewayHTTP, serviceHTTP

        var error: any Error {
            switch self {
            case .url: URLError(.timedOut)
            case .nsURL: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            case .requestHTTP: AgentClientTransportError.httpError(provider: .custom, status: 408, body: "Request timed out")
            case .gatewayHTTP: AgentClientTransportError.httpError(provider: .custom, status: 504, body: "Gateway timed out")
            case .serviceHTTP: AgentServiceError.httpError(status: 504, code: nil, message: "Gateway timed out")
            }
        }
    }

    enum NonTimeoutFailure: CaseIterable {
        case quota, authentication, credits, refusal, stream, connectionLost, cancelled, nsCancelled, foreignTimeout

        var isCancellation: Bool { self == .cancelled || self == .nsCancelled }

        var error: any Error {
            switch self {
            case .quota: AgentClientTransportError.httpError(provider: .custom, status: 429, body: "quota exceeded")
            case .authentication: AgentServiceError.unauthenticated
            case .credits: AgentServiceError.insufficientCredits("Insufficient credits")
            case .refusal: AgentServiceError.refusal(.terra)
            case .stream: AgentClientTransportError.streamError(provider: .custom, message: "Incomplete response")
            case .connectionLost: URLError(.networkConnectionLost)
            case .cancelled: URLError(.cancelled)
            case .nsCancelled: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            case .foreignTimeout: NSError(domain: "RecoveryFixture", code: NSURLErrorTimedOut)
            }
        }
    }

    enum LifecycleChange: CaseIterable { case cancel, sessionSwitch, editorChange, close }

    private func start(_ service: AgentService, client: RecoveryClient) -> Task<Void, Never> {
        service.kickOffStream(conversationID: service.currentSessionId!, traceID: UUID(),
                             settings: service.snapshotRunSettings(), client: client)
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        for block in result.content {
            if case .text(let text, _, _) = block {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func withRuntime(_ operation: @MainActor (AgentService, EditorViewModel, Client, UndoManager) async throws -> Void) async throws {
        let suite = "agent-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let skills = SkillStore(directory: directory.appendingPathComponent("skills"))
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline()
        let asset = MediaAsset(id: "source", url: directory.appendingPathComponent("original.png"),
                               type: .image, name: "Source", duration: 5)
        editor.mediaAssets = [asset]
        let undo = UndoManager()
        editor.undo.attach(undo)
        let service = AgentService(userDefaults: defaults, skillStore: skills)
        service.editor = editor
        let session = ChatSession(messages: [AgentMessage(role: .user, blocks: [.text("Edit the scene")])])
        service.sessions = [session]
        service.currentSessionId = session.id
        service.messages = session.messages
        let server = Server(name: "recovery-tests", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        let transport = await InMemoryTransport.createConnectedPair()
        let mcp = Client(name: "recovery-tests", version: "1")
        do {
            try await asset.prepareInputIdentity()
            editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
            await MCPService.registerTools(on: server, executor: ToolExecutor(editor: editor, skillStore: skills, userDefaults: defaults))
            try await server.start(transport: transport.server)
            _ = try await mcp.connect(transport: transport.client)
            try await operation(service, editor, mcp, undo)
        } catch {
            await service.cancelAndWait()
            await server.stop()
            await mcp.disconnect()
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        await service.cancelAndWait()
        await server.stop()
        await mcp.disconnect()
        try await MediaInputIdentityFixtures.remove(directory)
    }
}

private actor RecoveryClient: AgentClient {
    struct Request: Sendable {
        let messages: [AgentRequestMessage]
        let context: AgentRequestContext
    }

    struct Response: Sendable {
        var events: [AgentStreamEvent] = []
        var failure: (any Error)?

        static let finished = Response(events: [.textDelta("Done"), .messageStop(stopReason: .endTurn)])
        static let addClip = Response(events: [
            .toolUseComplete(id: "completed_edit", name: "add_clips", inputJSON: RecoveryClient.clipInput),
            .messageStop(stopReason: .toolUse),
        ])
    }

    static let clipInput = #"{"entries":[{"mediaRef":"source","startFrame":0,"endFrame":60}]}"#
    let cleanupEntered = RecoveryGate()
    let cleanupCancelled = RecoveryGate()
    let cleanupRelease = RecoveryGate()
    private let responses: [Response]
    private let heldCleanupIndex: Int?
    private let onRequest: (@MainActor @Sendable () -> Void)?
    private(set) var requests: [Request] = []

    init(_ responses: [Response], heldCleanupIndex: Int? = nil,
         onRequest: (@MainActor @Sendable () -> Void)? = nil) {
        self.responses = responses
        self.heldCleanupIndex = heldCleanupIndex
        self.onRequest = onRequest
    }

    nonisolated func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                            context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in
            try await self.respond(messages: messages, context: context, continuation: continuation)
        }
    }

    private func respond(messages: [AgentRequestMessage], context: AgentRequestContext,
                         continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) async throws {
        try Task.checkCancellation()
        let index = requests.count
        requests.append(Request(messages: messages, context: context))
        await onRequest?()
        guard responses.indices.contains(index) else { throw CocoaError(.coderReadCorrupt) }
        let response = responses[index]
        for event in response.events { continuation.yield(event) }
        if let failure = response.failure { continuation.finish(throwing: failure) }
        if heldCleanupIndex == index {
            let cleanupCancelled = cleanupCancelled
            await withTaskCancellationHandler {
                await cleanupEntered.open()
                await cleanupRelease.wait()
            } onCancel: {
                Task { await cleanupCancelled.open() }
            }
        }
        if let failure = response.failure { throw failure }
        try Task.checkCancellation()
    }
}

@MainActor private final class RequestProgressRecorder {
    var progress: [AgentRequestProgress?] = []
}

private actor RecoveryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
