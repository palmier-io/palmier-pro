import Foundation
import MCP

protocol MCPServiceListener: AnyObject, Sendable {
    func start() async throws
    func stop() async
}

extension MCPHTTPServer: MCPServiceListener {}

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private static let enabledKey = "io.compositor.pro.mcp.enabled"

    static var isEnabledPreference: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    enum State: Equatable {
        case stopped, starting, running, stopping
        case failed(String)
    }

    private(set) var state: State = .stopped

    var isRunning: Bool { state == .running }
    var isStarting: Bool { state == .starting }
    var startupError: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    @ObservationIgnored
    private let projectProvider: () -> VideoProject?
    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let listenerPort: UInt16
    @ObservationIgnored
    private let injectedListener: (any MCPServiceListener)?
    @ObservationIgnored
    private var httpServer: (any MCPServiceListener)?
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var shutdownTask: Task<Void, Never>?

    init(
        projectProvider: @escaping () -> VideoProject?,
        port: UInt16 = MCPService.port,
        listener: (any MCPServiceListener)? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.projectProvider = projectProvider
        self.listenerPort = port
        self.injectedListener = listener
        self.userDefaults = userDefaults
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        if state == .starting { return startupTask }
        guard state != .running, state != .stopping else { return nil }
        let httpServer = injectedListener ?? MCPHTTPServer(port: listenerPort) { [self] in
            let toolExecutor = await makeSessionToolExecutor()
            let server = Server(
                name: "compositor-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions + AgentInstructions.projectNavigation,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: true)
                )
            )
            await Self.registerTools(on: server, executor: toolExecutor)
            await Self.registerResources(on: server)
            return MCPServerInstance(server: server) { clientInfo in
                await toolExecutor.setMCPClientInfo(MCPClientInfo(clientInfo))
            }
        }
        self.httpServer = httpServer
        state = .starting
        let task = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                try await httpServer.start()
                try Task.checkCancellation()
                guard state == .starting, self.httpServer === httpServer else {
                    await httpServer.stop()
                    return
                }
                state = .running
                startupTask = nil
                Log.mcp.notice("http server started port=\(self.listenerPort)")
            } catch {
                await httpServer.stop()
                guard state == .starting, self.httpServer === httpServer else { return }
                self.httpServer = nil
                startupTask = nil
                if error is CancellationError {
                    state = .stopped
                } else {
                    state = .failed(error.localizedDescription)
                    Log.mcp.error("http server failed to start port=\(self.listenerPort): \(error.localizedDescription)")
                }
            }
        }
        startupTask = task
        return task
    }

    func makeSessionToolExecutor() -> ToolExecutor {
        ToolExecutor(projectProvider: projectProvider, userDefaults: userDefaults)
    }

    func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard let server = httpServer else {
            state = .stopped
            return
        }
        state = .stopping
        let startup = startupTask
        startup?.cancel()
        let task = Task { @MainActor [self] in
            await server.stop()
            await startup?.value
            guard state == .stopping, httpServer === server else { return }
            httpServer = nil
            startupTask = nil
            shutdownTask = nil
            state = .stopped
            Log.mcp.notice("http server stopped")
        }
        shutdownTask = task
        await task.value
    }

    @MainActor
    static func registerTools(on server: Server, executor: ToolExecutor) async {
        await executor.pluginRegistry.ensureLoaded()
        let tools: [Tool] = ToolDefinitions.mcpServer.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        } + executor.pluginTools.map { plugin in
            Tool(name: plugin.name, description: plugin.description, inputSchema: AgentTool.jsonValue(plugin.inputSchema))
        }
        await registerTools(on: server, tools: tools) { params in
            await dispatchCall(params, executor: executor)
        }
    }

    nonisolated static func registerTools(
        on server: Server,
        definitions: [AgentTool],
        enforceCatalog: Bool = true,
        call: @escaping @Sendable (CallTool.Parameters) async -> CallTool.Result
    ) async {
        let tools: [Tool] = definitions.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }
        await registerTools(on: server, tools: tools, enforceNames: enforceCatalog, call: call)
    }

    nonisolated static func registerTools(
        on server: Server,
        tools: [Tool],
        enforceNames: Bool = true,
        call: @escaping @Sendable (CallTool.Parameters) async -> CallTool.Result
    ) async {
        let names = Set(tools.map(\.name))

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard !enforceNames || names.contains(params.name) else {
                return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
            return await call(params)
        }
    }

    // Convert args on the main actor so the non-Sendable dict never crosses the hop.
    private static func dispatchCall(_ params: CallTool.Parameters, executor: ToolExecutor) async -> CallTool.Result {
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await executor.execute(name: params.name, args: args, source: "mcp")
        return result.toMCPResult()
    }

    private nonisolated static func registerResources(on server: Server) async {
        let resources = [
            Resource(
                name: "Video Models",
                uri: "compositor://models/video",
                description: "Available AI video generation models and their capabilities",
                mimeType: "application/json"
            ),
            Resource(
                name: "Image Models",
                uri: "compositor://models/image",
                description: "Available AI image generation models and their capabilities",
                mimeType: "application/json"
            ),
        ]

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            await Self.readResource(uri: params.uri)
        }
    }

    @MainActor
    private static func readResource(uri: String) -> ReadResource.Result {
        switch uri {
        case "compositor://models/video":
            let json = ToolExecutor.jsonString(VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "compositor://models/image":
            let json = ToolExecutor.jsonString(ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
