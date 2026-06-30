import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private static let enabledKey = "io.palmier.pro.mcp.enabled"

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

    private(set) var isRunning: Bool = false

    @ObservationIgnored
    private let toolExecutor: ToolExecutor
    @ObservationIgnored
    private var httpServer: MCPHTTPServer?

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.toolExecutor = ToolExecutor(editorProvider: editorProvider)
    }

    func start() {
        let toolExecutor = toolExecutor
        let httpServer = MCPHTTPServer(port: Self.port) {
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: false)
                )
            )
            await Self.registerTools(on: server, toolExecutor: toolExecutor)
            await Self.registerResources(on: server)
            return server
        }
        self.httpServer = httpServer
        Task { @MainActor [weak self] in
            do {
                try await httpServer.start()
                Log.mcp.notice("http server started port=\(Self.port)")
                self?.isRunning = true
            } catch {
                Log.mcp.error("http server failed to start: \(error.localizedDescription)")
                self?.isRunning = false
            }
        }
    }

    func stop() {
        if let server = httpServer {
            Task { await server.stop() }
        }
        httpServer = nil
        isRunning = false
        Log.mcp.notice("http server stopped")
    }

    private nonisolated static func registerTools(on server: Server, toolExecutor: ToolExecutor) async {
        let tools: [Tool] = ToolDefinitions.all.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.dispatchCall(params, toolExecutor: toolExecutor)
        }
    }

    private nonisolated static func dispatchCall(_ params: CallTool.Parameters, toolExecutor: ToolExecutor) async -> CallTool.Result {
        guard ToolName(rawValue: params.name) != nil else {
            return ToolResult.error("Unknown tool: \(params.name)").toMCPResult()
        }
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await toolExecutor.execute(name: params.name, args: args)
        return result.toMCPResult()
    }

    private nonisolated static func registerResources(on server: Server) async {
        let resources = [
            Resource(
                name: "Video Models",
                uri: "palmier://models/video",
                description: "Available AI video generation models and their capabilities",
                mimeType: "application/json"
            ),
            Resource(
                name: "Image Models",
                uri: "palmier://models/image",
                description: "Available AI image generation models and their capabilities",
                mimeType: "application/json"
            ),
        ]

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            await readResource(uri: params.uri)
        }
    }

    private nonisolated static func readResource(uri: String) async -> ReadResource.Result {
        switch uri {
        case "palmier://models/video":
            let models = await MainActor.run { VideoModelConfig.allModels }
            let json = await Task.detached(priority: .utility) {
                ToolExecutor.jsonString(models.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            }.value
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "palmier://models/image":
            let models = await MainActor.run { ImageModelConfig.allModels }
            let json = await Task.detached(priority: .utility) {
                ToolExecutor.jsonString(models.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            }.value
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
