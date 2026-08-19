import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    nonisolated static let port: UInt16 = 19789

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
    private let projectProvider: () -> VideoProject?
    @ObservationIgnored
    private var httpServer: MCPHTTPServer?
    @ObservationIgnored
    private var previewNotifyTask: Task<Void, Never>?

    init(projectProvider: @escaping () -> VideoProject?) {
        self.projectProvider = projectProvider
    }

    func start() {
        let httpServer = MCPHTTPServer(
            port: Self.port,
            previewMedia: { mediaRef in
                await MainActor.run { Self.previewMediaFile(mediaRef: mediaRef) }
            }
        ) { [self] in
            let toolExecutor = await makeSessionToolExecutor()
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions + AgentInstructions.projectNavigation,
                capabilities: .init(
                    resources: .init(subscribe: true, listChanged: false),
                    tools: .init(listChanged: true)
                )
            )
            await Self.registerTools(on: server, executor: toolExecutor)
            await Self.registerResources(on: server, executor: toolExecutor)
            return MCPServerInstance(server: server) { clientInfo in
                await toolExecutor.setMCPClientInfo(MCPClientInfo(clientInfo))
            }
        }
        self.httpServer = httpServer
        previewNotifyTask?.cancel()
        previewNotifyTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .generationAssetDidChange) {
                guard !Task.isCancelled, let mediaRef = note.object as? String else { continue }
                await self?.httpServer?.notifyResourceUpdated(
                    uri: MCPPreviewApp.previewResourceURI(mediaRef: mediaRef)
                )
            }
        }
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

    func makeSessionToolExecutor() -> ToolExecutor {
        ToolExecutor(projectProvider: projectProvider)
    }

    func stop() {
        previewNotifyTask?.cancel()
        previewNotifyTask = nil
        if let server = httpServer {
            Task { await server.stop() }
        }
        httpServer = nil
        isRunning = false
        Log.mcp.notice("http server stopped")
    }

    nonisolated static func registerTools(on server: Server, executor: ToolExecutor) async {
        let tools: [Tool] = ToolDefinitions.mcpServer.map { def in
            Tool(
                name: def.name.rawValue,
                description: def.description,
                inputSchema: def.mcpSchemaValue,
                _meta: MCPPreviewApp.meta(for: def.name)
            )
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

    private nonisolated static func registerResources(on server: Server, executor: ToolExecutor) async {
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
            MCPPreviewApp.resource,
        ]

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            await Self.readResource(uri: params.uri, executor: executor)
        }

        await server.withMethodHandler(ResourceSubscribe.self) { _ in
            Empty()
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { _ in
            Empty()
        }
    }

    @MainActor
    private static func readResource(uri: String, executor: ToolExecutor) async -> ReadResource.Result {
        switch uri {
        case "palmier://models/video":
            let json = ToolExecutor.jsonString(VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "palmier://models/image":
            let json = ToolExecutor.jsonString(ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case MCPPreviewApp.resourceURI:
            return .init(contents: [
                .text(MCPPreviewApp.html, uri: uri, mimeType: MCPPreviewApp.mimeType, _meta: MCPPreviewApp.resourceMeta)
            ])
        default:
            if let mediaRef = MCPPreviewApp.previewResourceMediaRef(uri) {
                let json = await executor.generationPreviewJSON(mediaRef: mediaRef)
                return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
            }
            if let mediaRef = MCPPreviewApp.generationMediaRef(uri) {
                return await Self.readGenerationMedia(uri: uri, mediaRef: mediaRef)
            }
            if let iconKey = MCPPreviewApp.modelIconKey(uri) {
                let png = await Task.detached(priority: .utility) {
                    MCPPreviewApp.modelIconPNG(iconKey: iconKey)
                }.value
                if let png {
                    return .init(contents: [
                        .binary(png, uri: uri, mimeType: "image/png")
                    ])
                }
            }
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

    @MainActor
    private static func readGenerationMedia(uri: String, mediaRef: String) async -> ReadResource.Result {
        guard let file = previewMediaFile(mediaRef: mediaRef) else {
            return .init(contents: [])
        }
        let loaded = await Task.detached(priority: .userInitiated) { () -> Data? in
            let values = try? file.url.resourceValues(forKeys: [.fileSizeKey])
            let size = values?.fileSize ?? 0
            guard size > 0, size <= MCPPreviewApp.maxHTTPMediaBytes else { return nil }
            return try? Data(contentsOf: file.url)
        }.value
        guard let data = loaded else {
            return .init(contents: [])
        }
        return .init(contents: [.binary(data, uri: uri, mimeType: file.mimeType)])
    }

    @MainActor
    private static func previewMediaFile(mediaRef: String) -> (url: URL, mimeType: String)? {
        guard MCPPreviewApp.isPreviewMediaRef(mediaRef) else { return nil }
        for project in AppState.shared.openProjects {
            guard let asset = project.editorViewModel.mediaAssets.first(where: { $0.id == mediaRef }) else {
                continue
            }
            guard asset.generationStatus == .none else { return nil }
            return (asset.url, MCPPreviewApp.httpMediaMIMEType(url: asset.url, type: asset.type))
        }
        return nil
    }

}
