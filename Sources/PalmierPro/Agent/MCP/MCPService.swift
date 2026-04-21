import Foundation
import MCP

/// MCP HTTP adapter on localhost:19789. Tool handling lives in `ToolExecutor`.
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private weak var editor: EditorViewModel?
    private let toolExecutor: ToolExecutor
    private var httpServer: MCPHTTPServer?

    init(editor: EditorViewModel) {
        self.editor = editor
        self.toolExecutor = ToolExecutor(editor: editor)
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port) { [weak self] in
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions,
                capabilities: .init(
                    prompts: .init(listChanged: false),
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: false)
                )
            )
            await self?.registerTools(on: server)
            await self?.registerResources(on: server)
            await self?.registerPrompts(on: server)
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

    private func registerPrompts(on server: Server) async {
        let prompts = [
            Prompt(
                name: "generate_video",
                description: "Generate an AI video clip from a text description",
                arguments: [
                    .init(name: "description", description: "What the video should depict", required: true),
                    .init(name: "style", description: "Visual style (e.g. cinematic, anime, documentary)", required: false),
                    .init(name: "duration", description: "Length in seconds", required: false),
                ]
            ),
            Prompt(
                name: "generate_image",
                description: "Generate an AI image from a text description",
                arguments: [
                    .init(name: "description", description: "What the image should depict", required: true),
                    .init(name: "style", description: "Visual style (e.g. photorealistic, illustration, 3D render)", required: false),
                ]
            ),
        ]

        await server.withMethodHandler(ListPrompts.self) { _ in
            .init(prompts: prompts)
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            switch params.name {
            case "generate_video":
                let desc = params.arguments?["description"] ?? "a beautiful scene"
                let style = params.arguments?["style"] ?? ""
                let duration = params.arguments?["duration"] ?? "6"
                let styleClause = style.isEmpty ? "" : " in a \(style) style"
                return .init(
                    description: "Generate a video clip",
                    messages: [
                        .user(.text(text: """
                            Generate a \(duration)s video clip\(styleClause) for the editor timeline. Think about how it fits into a larger edit, not just how it looks standalone.

                            Description: \(desc)

                            Model selection: pick one whose `durations` includes \(duration)s and whose aspectRatios fit the project. If continuity with an existing asset matters, prefer supportsFirstFrame / supportsLastFrame and pass the asset as startFrameMediaRef / endFrameMediaRef.
                            """))
                    ]
                )

            case "generate_image":
                let desc = params.arguments?["description"] ?? "a beautiful scene"
                let style = params.arguments?["style"] ?? ""
                let styleClause = style.isEmpty ? "" : " in a \(style) style"
                return .init(
                    description: "Generate an image",
                    messages: [
                        .user(.text(text: """
                            Generate an image\(styleClause) that will likely become the first frame of a scene — think about composition, light, and camera, not just subject.

                            Description: \(desc)

                            Model selection: pick one whose aspectRatios fit the project. If you need character / style / location consistency with existing assets, prefer supportsImageReference and pass those via referenceMediaRefs.
                            """))
                    ]
                )

            default:
                throw MCPError.invalidRequest("Unknown prompt: \(params.name)")
            }
        }
    }
}
