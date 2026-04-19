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
                            You are a creative director generating a \(duration)s video clip\(styleClause) for an editor timeline. Think about how this clip fits into a larger edit, not just how it looks standalone.

                            Description: \(desc)

                            Model selection priority, in order:
                            1. Reference frames — if continuity with an existing asset matters, you need a model with supportsFirstFrame (for startFrameMediaRef) or supportsLastFrame (for endFrameMediaRef).
                            2. Duration — \(duration)s must be in the model's `durations` list.
                            3. Aspect ratio and resolution — match the project's settings from get_timeline.
                            4. Cost and speed.

                            Reference-image discipline: if you pass startFrameMediaRef or endFrameMediaRef, call read_media on that asset first and describe what you actually see in the prompt. Never rely on the handle name or filename.

                            Text in video: video models cannot render readable text. For on-screen text, use generate_image to make a still with the text baked in, then pass it as startFrameMediaRef.

                            Permission: generation costs real money and is not undoable. Propose the prompt, chosen model, duration, and aspect ratio to the user and get confirmation before calling generate_video.

                            Placeholder-then-poll: generate_video returns immediately with a placeholder asset ID. The asset appears in get_media with generationStatus: generating. Poll get_media until the status clears; then the ID is drop-in usable in add_clip.

                            Workflow:
                            1. get_timeline and get_media to see the project settings and existing assets that could be reference frames.
                            2. list_models with type "video".
                            3. Pick a model using the priority above; draft a grounded, concrete prompt.
                            4. Propose the plan to the user and wait for confirmation.
                            5. Call generate_video.
                            6. Poll get_media until generationStatus clears.
                            7. Use the asset in add_clip when the user is ready to drop it on the timeline.
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
                            You are a creative director generating an image\(styleClause) that will likely become the first frame of a scene. Think about composition, light, and camera — not just subject.

                            Description: \(desc)

                            Model selection priority, in order:
                            1. Reference support — if you need character/style/location consistency with existing assets, use a model with supportsImageReference and pass those assets via referenceMediaRefs.
                            2. Aspect ratio and resolution — match the project's settings from get_timeline.
                            3. Cost and speed.

                            Reference-image discipline: before passing any ID in referenceMediaRefs, call read_media on it and describe what you actually see in the prompt. Never rely on the handle name or filename.

                            Permission: generation costs real money and is not undoable. Propose the prompt, chosen model, and aspect ratio to the user and get confirmation before calling generate_image.

                            Placeholder-then-poll: generate_image returns immediately with a placeholder asset ID. The asset appears in get_media with generationStatus: generating. Poll get_media until the status clears; then the ID is usable as a reference for generate_video or as a clip via add_clip on an image track.

                            Workflow:
                            1. get_timeline and get_media to see the project settings and existing assets that could serve as references.
                            2. list_models with type "image".
                            3. Pick a model using the priority above; draft a grounded, concrete prompt.
                            4. Propose the plan to the user and wait for confirmation.
                            5. Call generate_image.
                            6. Poll get_media until generationStatus clears.
                            """))
                    ]
                )

            default:
                throw MCPError.invalidRequest("Unknown prompt: \(params.name)")
            }
        }
    }
}
