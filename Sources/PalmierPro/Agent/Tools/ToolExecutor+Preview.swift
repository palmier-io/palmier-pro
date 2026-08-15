import Foundation
import MCP

extension ToolExecutor {
    private static let showPreviewAllowedKeys: Set<String> = ["mediaRef", "mediaRefs"]

    func showPreview(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.showPreviewAllowedKeys, path: "show_preview")
        var ids: [String] = []
        var seen = Set<String>()
        func append(_ id: String) {
            guard seen.insert(id).inserted else { return }
            ids.append(id)
        }
        if let single = args.string("mediaRef") { append(single) }
        for id in args.stringArray("mediaRefs") { append(id) }
        guard !ids.isEmpty else {
            throw ToolError("show_preview requires mediaRef or mediaRefs.")
        }
        guard ids.count <= MCPPreviewApp.maxAssets else {
            throw ToolError("show_preview accepts at most \(MCPPreviewApp.maxAssets) assets.")
        }

        var items: [PreviewItem] = []
        items.reserveCapacity(ids.count)
        for id in ids {
            items.append(try await previewItem(id, editor: editor))
        }

        var payload: [String: Any] = [
            "items": items.map(\.json),
        ]
        if let first = items.first {
            payload["mediaRef"] = first.mediaRef
            payload["name"] = first.name
            payload["type"] = first.kind.rawValue
            if let url = first.url { payload[first.kind.urlKey] = url }
            if let width = first.width { payload["width"] = width }
            if let height = first.height { payload["height"] = height }
            if let duration = first.durationSeconds { payload["durationSeconds"] = duration }
            if let generation = first.generation { payload["generation"] = generation.json }
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("Failed to encode preview")
        }
        return ToolResult(
            content: [.text(json)],
            isError: false,
            structuredContent: .object([
                "items": .array(items.map(\.value)),
            ]),
            mcpMeta: MCPPreviewApp.toolMeta
        )
    }

    private func previewItem(_ mediaRef: String, editor: EditorViewModel) async throws -> PreviewItem {
        let asset = try asset(mediaRef, editor: editor)
        let kind: MCPPreviewStore.Item.Kind
        switch asset.type {
        case .video: kind = .video
        case .image: kind = .image
        case .audio: kind = .audio
        case .text, .lottie, .sequence, .subtitle:
            throw ToolError(
                "show_preview cannot play \(asset.type.rawValue) assets. Use inspect_media or inspect_timeline."
            )
        }
        let url = asset.url
        let name = asset.name
        let duration = asset.duration
        let width = asset.sourceWidth
        let height = asset.sourceHeight
        let mime = MCPPreviewApp.mimeType(for: url, type: asset.type)
        let generation = PreviewGeneration(asset)
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.isReadableFile(atPath: url.path)
        }.value
        let previewURL: String?
        if exists {
            let token = await MCPPreviewStore.shared.register(
                MCPPreviewStore.Item(url: url, mimeType: mime, kind: kind)
            )
            previewURL = MCPPreviewApp.previewURL(token: token)
        } else if asset.isGenerating {
            previewURL = nil
        } else {
            throw ToolError("Media file not on disk: \(url.lastPathComponent)")
        }
        return PreviewItem(
            mediaRef: mediaRef,
            name: name,
            kind: kind,
            url: previewURL,
            width: width,
            height: height,
            durationSeconds: duration > 0 ? duration : nil,
            generation: generation
        )
    }
}

private struct PreviewGeneration {
    let prompt: String?
    let model: String
    let modelId: String
    let aspectRatio: String?
    let status: String?

    @MainActor
    init?(_ asset: MediaAsset) {
        guard let input = asset.generationInput else { return nil }
        let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt.isEmpty ? nil : String(prompt.prefix(160))
        self.modelId = input.model
        self.model = ModelRegistry.displayName(for: input.model)
        self.aspectRatio = input.aspectRatio.isEmpty ? nil : input.aspectRatio
        switch asset.generationStatus {
        case .none: status = nil
        default: status = asset.generationStatus.serialized
        }
    }

    var json: [String: Any] {
        var obj: [String: Any] = [
            "model": model,
            "modelId": modelId,
        ]
        if let prompt { obj["prompt"] = prompt }
        if let aspectRatio { obj["aspectRatio"] = aspectRatio }
        if let status { obj["status"] = status }
        return obj
    }

    var value: Value {
        var obj: [String: Value] = [
            "model": .string(model),
            "modelId": .string(modelId),
        ]
        if let prompt { obj["prompt"] = .string(prompt) }
        if let aspectRatio { obj["aspectRatio"] = .string(aspectRatio) }
        if let status { obj["status"] = .string(status) }
        return .object(obj)
    }
}

private struct PreviewItem {
    let mediaRef: String
    let name: String
    let kind: MCPPreviewStore.Item.Kind
    let url: String?
    let width: Int?
    let height: Int?
    let durationSeconds: Double?
    let generation: PreviewGeneration?

    var json: [String: Any] {
        var obj: [String: Any] = [
            "mediaRef": mediaRef,
            "name": name,
            "type": kind.rawValue,
        ]
        if let url { obj["url"] = url }
        if let width { obj["width"] = width }
        if let height { obj["height"] = height }
        if let durationSeconds { obj["durationSeconds"] = durationSeconds }
        if let generation { obj["generation"] = generation.json }
        return obj
    }

    var value: Value {
        var obj: [String: Value] = [
            "mediaRef": .string(mediaRef),
            "name": .string(name),
            "type": .string(kind.rawValue),
        ]
        if let url { obj["url"] = .string(url) }
        if let width { obj["width"] = .int(width) }
        if let height { obj["height"] = .int(height) }
        if let durationSeconds { obj["durationSeconds"] = .double(durationSeconds) }
        if let generation { obj["generation"] = generation.value }
        return .object(obj)
    }
}

private extension MCPPreviewStore.Item.Kind {
    var urlKey: String {
        switch self {
        case .video: "videoUrl"
        case .image: "imageUrl"
        case .audio: "audioUrl"
        }
    }
}
