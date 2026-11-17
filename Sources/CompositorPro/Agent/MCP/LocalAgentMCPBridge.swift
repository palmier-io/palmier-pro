import Foundation
import MCP

@MainActor
final class LocalAgentMCPBridge {
    private let executor: ToolExecutor
    private let conversationID: UUID
    private let isActive: @MainActor @Sendable () -> Bool
    private var listener: MCPHTTPServer?
    private var calls: [UUID: Task<CallTool.Result, Never>] = [:]
    private var stopped = false

    init(executor: ToolExecutor, conversationID: UUID,
         isActive: @escaping @MainActor @Sendable () -> Bool) {
        self.executor = executor
        self.conversationID = conversationID
        self.isActive = isActive
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
        let id = UUID()
        let task = Task { [weak self, executor, conversationID] in
            guard let self, !self.stopped, self.isActive(), !Task.isCancelled else {
                return CallTool.Result(content: [.text(text: "operation_canceled", annotations: nil, _meta: nil)], isError: true)
            }
            let arguments = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
            return await executor.execute(name: params.name, args: arguments,
                                          source: "agent", sessionID: conversationID.uuidString).toMCPResult()
        }
        calls[id] = task
        let result = await task.value
        calls[id] = nil
        guard !stopped, isActive() else { return .init(content: [.text(text: "operation_canceled", annotations: nil, _meta: nil)], isError: true) }
        return result
    }

    func stop() async {
        stopped = true
        let pending = Array(calls.values)
        pending.forEach { $0.cancel() }
        let closing = listener
        listener = nil
        await closing?.stop()
        for task in pending { _ = await task.value }
        calls.removeAll()
    }
}
