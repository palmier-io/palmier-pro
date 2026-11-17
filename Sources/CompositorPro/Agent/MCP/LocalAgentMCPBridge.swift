import Foundation
import MCP
import Synchronization

@MainActor
final class LocalAgentMCPBridge {
    private let executor: ToolExecutor
    private let conversationID: UUID
    private let isActive: @MainActor @Sendable () -> Bool
    private let onActivity: @Sendable () -> Void
    private var listener: MCPHTTPServer?
    private struct CallState {
        var cancelled = false
        var tasks: [UUID: Task<CallTool.Result, Never>] = [:]
    }
    private nonisolated let calls = Mutex(CallState())
    private var stopTask: Task<Void, Never>?
    private nonisolated var stopped: Bool { calls.withLock { $0.cancelled } }

    init(executor: ToolExecutor, conversationID: UUID,
         onActivity: @escaping @Sendable () -> Void = {},
         isActive: @escaping @MainActor @Sendable () -> Bool) {
        self.executor = executor
        self.conversationID = conversationID
        self.onActivity = onActivity
        self.isActive = isActive
    }

    func withConnection(_ operation: @MainActor (URL) async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            do {
                let endpoint = try await start()
                try await operation(endpoint)
            } catch {
                await stop()
                throw error
            }
            await stop()
            try Task.checkCancellation()
        } onCancel: {
            self.cancel()
        }
    }

    func start() async throws -> URL {
        guard !stopped, isActive(), !Task.isCancelled else { throw CancellationError() }
        let listener = MCPHTTPServer(port: 0) { [weak self] in
            let server = Server(name: "compositor-pro", version: "1",
                                instructions: AgentInstructions.serverInstructions,
                                capabilities: .init(tools: .init(listChanged: false)))
            await MCPService.registerTools(on: server, definitions: ToolDefinitions.inAppAgent) { [weak self] params in
                guard let self else { return .init(content: [.text(text: "operation_canceled", annotations: nil, _meta: nil)], isError: true) }
                return await self.execute(params)
            }
            return MCPServerInstance(server: server, onInitialize: { _ in })
        }
        self.listener = listener
        try await listener.start()
        guard !stopped, isActive(), !Task.isCancelled, let port = await listener.listeningPort else {
            await listener.stop()
            throw CancellationError()
        }
        return URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    private func execute(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard !stopped, isActive(), !Task.isCancelled else {
            return .init(content: [.text(text: "operation_canceled", annotations: nil, _meta: nil)], isError: true)
        }
        onActivity()
        defer { onActivity() }
        let id = UUID()
        let task = Task { [weak self, executor, conversationID] in
            guard let self, !self.stopped, self.isActive(), !Task.isCancelled else {
                return CallTool.Result(content: [.text(text: "operation_canceled", annotations: nil, _meta: nil)], isError: true)
            }
            let arguments = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
            return await executor.execute(name: params.name, args: arguments,
                                          source: "agent", sessionID: conversationID.uuidString).toMCPResult()
        }
        let registered = calls.withLock { state in
            guard !state.cancelled else { return false }
            state.tasks[id] = task
            return true
        }
        if !registered { task.cancel() }
        let result = await task.value
        calls.withLock { $0.tasks[id] = nil }
        guard !stopped, isActive() else { return .init(content: [.text(text: "operation_canceled", annotations: nil, _meta: nil)], isError: true) }
        return result
    }

    nonisolated func cancel() {
        let pending = calls.withLock { state in
            state.cancelled = true
            return Array(state.tasks.values)
        }
        pending.forEach { $0.cancel() }
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        cancel()
        let pending = calls.withLock { Array($0.tasks.values) }
        let closing = listener
        listener = nil
        let task = Task {
            await closing?.stop()
            for task in pending { _ = await task.value }
        }
        stopTask = task
        await task.value
    }
}
