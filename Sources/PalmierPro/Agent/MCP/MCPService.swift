import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private let toolExecutor: ToolExecutor
    private var httpServer: MCPHTTPServer?

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.toolExecutor = ToolExecutor(editorProvider: editorProvider)
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port) { [weak self] in
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: false)
                )
            )
            await self?.registerTools(on: server)
            await self?.registerResources(on: server)
            return server
        }
        self.httpServer = httpServer
        Task {
            do {
                try await httpServer.start()
                Log.mcp.notice("http server started port=\(Self.port)")
            } catch {
                Log.mcp.error("http server failed to start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        if let server = httpServer {
            Task { await server.stop() }
        }
        httpServer = nil
        Log.mcp.notice("http server stopped")
    }

    private func registerTools(on server: Server) async {
        let tools: [Tool] = ToolDefinitions.all.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return ToolResult.error("Editor not available").toMCPResult()
            }
            return await self.dispatchCall(params)
        }
    }

    // Convert args inside the actor so the non-Sendable dict never crosses the hop.
    private func dispatchCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await toolExecutor.execute(name: params.name, args: args)
        return result.toMCPResult()
    }

    private func registerResources(on server: Server) async {
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
            Self.readResource(uri: params.uri)
        }
    }

    nonisolated private static func readResource(uri: String) -> ReadResource.Result {
        switch uri {
        case "palmier://models/video":
            let list = VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }
            let json = ToolExecutor.jsonString(list) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "palmier://models/image":
            let list = ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }
            let json = ToolExecutor.jsonString(list) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
