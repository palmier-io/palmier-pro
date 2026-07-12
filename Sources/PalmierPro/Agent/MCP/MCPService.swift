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
        let toolExecutor = self.toolExecutor
        let httpServer = MCPHTTPServer(
            port: Self.port,
            onSessionStarted: {
                Analytics.capture(.mcpSessionStarted, properties: ["source": "mcp"])
            }
        ) {
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions + AgentInstructions.projectNavigation,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: false)
                )
            )
            await Self.registerTools(on: server, executor: toolExecutor)
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

    private nonisolated static func registerTools(on server: Server, executor: ToolExecutor) async {
        let tools: [Tool] = ToolDefinitions.mcpServer.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await dispatchCall(params, executor: executor)
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
            await Self.readResource(uri: params.uri)
        }
    }

    @MainActor
    private static func readResource(uri: String) -> ReadResource.Result {
        switch uri {
        case "palmier://models/video":
            let json = ToolExecutor.jsonString(VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "palmier://models/image":
            let json = ToolExecutor.jsonString(ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
