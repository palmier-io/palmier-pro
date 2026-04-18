import Foundation
import ImageIO
import MCP

/// MCP server exposing editor tools over HTTP on localhost:19789.
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private enum ToolName: String {
        case getTimeline = "get_timeline"
        case getMedia = "get_media"
        case addTrack = "add_track"
        case removeTrack = "remove_track"
        case addClip = "add_clip"
        case removeClip = "remove_clip"
        case updateClip = "update_clip"
        case moveClip = "move_clip"
        case splitClip = "split_clip"
        case generateVideo = "generate_video"
        case generateImage = "generate_image"
        case listModels = "list_models"
        case readMedia = "read_media"
    }

    private static let defaultReadImageMaxBytes = 20 * 1024 * 1024

    /// Built without `toolText` so it can be used from MCP method-handler closures that are not on the main actor.
    nonisolated private static func editorUnavailableToolResult() -> CallTool.Result {
        .init(
            content: [.text(text: "Editor not available", annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private weak var editor: EditorViewModel?
    private var httpServer: MCPHTTPServer?
    private let generationService = GenerationService()

    init(editor: EditorViewModel) {
        self.editor = editor
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port) { [weak self] in
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
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

    // MARK: - Tools

    private func registerTools(on server: Server) async {
        let noArgsSchema = Value.object(["type": .string("object")])
        let tools = [
            Tool(
                name: ToolName.getTimeline.rawValue,
                description: "Get the full timeline including project settings (fps, resolution), all tracks, and all clips",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: ToolName.getMedia.rawValue,
                description: "List all available media assets in the project",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: ToolName.readMedia.rawValue,
                description: "Read an image asset: returns MCP image content (base64) plus JSON metadata (dimensions, file size, optional EXIF subset). Only image assets are supported; default max file size 20MB. Optional maxImageBytes overrides the cap.",
                inputSchema: Self.objectSchema(properties: [
                    "mediaRef": .object(["type": .string("string"), "description": .string("ID of the media asset from get_media")]),
                    "maxImageBytes": .object(["type": .string("integer"), "description": .string("Maximum file size in bytes (default 20971520)")]),
                ], required: ["mediaRef"])
            ),
            Tool(
                name: ToolName.addTrack.rawValue,
                description: "Add a new track to the timeline",
                inputSchema: Self.objectSchema(properties: [
                    "type": .object(["type": .string("string"), "enum": .array([.string("video"), .string("audio"), .string("image")]), "description": .string("Track type")]),
                    "label": .object(["type": .string("string"), "description": .string("Display label. Defaults to the type name (e.g. 'Video').")]),
                ], required: ["type"])
            ),
            Tool(
                name: ToolName.removeTrack.rawValue,
                description: "Remove a track and all its clips from the timeline",
                inputSchema: Self.objectSchema(properties: [
                    "trackId": .object(["type": .string("string"), "description": .string("The track ID to remove")]),
                ], required: ["trackId"])
            ),
            Tool(
                name: ToolName.addClip.rawValue,
                description: "Add a media asset as a clip on a track",
                inputSchema: Self.objectSchema(properties: [
                    "mediaRef": .object(["type": .string("string"), "description": .string("ID of the media asset from get_media")]),
                    "trackIndex": .object(["type": .string("integer"), "description": .string("Track index (0-based)")]),
                    "startFrame": .object(["type": .string("integer"), "description": .string("Frame position to place the clip")]),
                    "durationFrames": .object(["type": .string("integer"), "description": .string("Duration in frames")]),
                ], required: ["mediaRef", "trackIndex", "startFrame", "durationFrames"])
            ),
            Tool(
                name: ToolName.removeClip.rawValue,
                description: "Remove a clip from the timeline by its ID",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to remove")]),
                ], required: ["clipId"])
            ),
            Tool(
                name: ToolName.updateClip.rawValue,
                description: "Update properties of an existing clip (position, trim, speed, volume, opacity)",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to update")]),
                    "startFrame": .object(["type": .string("integer"), "description": .string("New start frame position")]),
                    "durationFrames": .object(["type": .string("integer"), "description": .string("New duration in frames")]),
                    "trimStartFrame": .object(["type": .string("integer"), "description": .string("Frames to trim from start of source")]),
                    "trimEndFrame": .object(["type": .string("integer"), "description": .string("Frames to trim from end of source")]),
                    "speed": .object(["type": .string("number"), "description": .string("Playback speed multiplier (default 1.0)")]),
                    "volume": .object(["type": .string("number"), "description": .string("Volume 0.0-1.0 (default 1.0)")]),
                    "opacity": .object(["type": .string("number"), "description": .string("Opacity 0.0-1.0 (default 1.0)")]),
                ], required: ["clipId"])
            ),
            Tool(
                name: ToolName.moveClip.rawValue,
                description: "Move a clip to a different track and/or frame position. Handles overlap resolution automatically.",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to move")]),
                    "toTrack": .object(["type": .string("integer"), "description": .string("Destination track index (0-based)")]),
                    "toFrame": .object(["type": .string("integer"), "description": .string("Destination frame position")]),
                ], required: ["clipId", "toTrack", "toFrame"])
            ),
            Tool(
                name: ToolName.splitClip.rawValue,
                description: "Split a clip into two at the specified frame. The frame must be within the clip's range.",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to split")]),
                    "atFrame": .object(["type": .string("integer"), "description": .string("Frame position to split at (must be between clip start and end)")]),
                ], required: ["clipId", "atFrame"])
            ),
            Tool(
                name: ToolName.generateVideo.rawValue,
                description: "Generate a video using AI. Returns immediately with a placeholder asset ID; the asset status transitions to complete once generation finishes.",
                inputSchema: Self.objectSchema(properties: [
                    "prompt": .object(["type": .string("string"), "description": .string("Text description of the video to generate")]),
                    "name": .object(["type": .string("string"), "description": .string("Display name for the asset in the media library. Defaults to first 30 chars of prompt.")]),
                    "model": .object(["type": .string("string"), "description": .string("Model ID (e.g. 'veo3.1-fast'). Use list_models to see options. Defaults to first available model.")]),
                    "duration": .object(["type": .string("integer"), "description": .string("Duration in seconds. Valid values depend on model.")]),
                    "aspectRatio": .object(["type": .string("string"), "description": .string("Aspect ratio (e.g. '16:9', '9:16', '1:1')")]),
                    "resolution": .object(["type": .string("string"), "description": .string("Resolution (e.g. '720p', '1080p', '4k')")]),
                    "startFrameMediaRef": .object(["type": .string("string"), "description": .string("Media asset ID to use as the first frame (image-to-video)")]),
                    "endFrameMediaRef": .object(["type": .string("string"), "description": .string("Media asset ID to use as the last frame (supported by some models)")]),
                ], required: ["prompt"])
            ),
            Tool(
                name: ToolName.generateImage.rawValue,
                description: "Generate an image using AI. Returns immediately with a placeholder asset ID; the asset status transitions to complete once generation finishes.",
                inputSchema: Self.objectSchema(properties: [
                    "prompt": .object(["type": .string("string"), "description": .string("Text description of the image to generate")]),
                    "name": .object(["type": .string("string"), "description": .string("Display name for the asset in the media library. Defaults to first 30 chars of prompt.")]),
                    "model": .object(["type": .string("string"), "description": .string("Model ID (e.g. 'nano-banana-pro'). Use list_models to see options. Defaults to first available model.")]),
                    "aspectRatio": .object(["type": .string("string"), "description": .string("Aspect ratio (e.g. '16:9', '9:16')")]),
                    "resolution": .object(["type": .string("string"), "description": .string("Resolution (e.g. '2K', '4K')")]),
                    "referenceMediaRefs": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Media asset IDs to use as reference images")]),
                ], required: ["prompt"])
            ),
            Tool(
                name: ToolName.listModels.rawValue,
                description: "List available AI generation models and their capabilities",
                inputSchema: Self.objectSchema(properties: [
                    "type": .object(["type": .string("string"), "enum": .array([.string("video"), .string("image")]), "description": .string("Filter by type. Omit to list all models.")]),
                ])
            ),
        ]

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            await self?.handleToolCall(params) ?? Self.editorUnavailableToolResult()
        }
    }

    // MARK: - Handlers

    private func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let editor else { return Self.editorUnavailableToolResult() }

        guard let tool = ToolName(rawValue: params.name) else {
            return toolError("Unknown tool: \(params.name)")
        }

        let args = params.arguments ?? [:]
        switch tool {
        case .getTimeline:   return getTimeline(editor)
        case .getMedia:      return getMedia(editor)
        case .addTrack:      return addTrack(editor, args: args)
        case .removeTrack:   return removeTrack(editor, args: args)
        case .addClip:       return addClip(editor, args: args)
        case .removeClip:    return removeClip(editor, args: args)
        case .updateClip:    return updateClip(editor, args: args)
        case .moveClip:      return moveClip(editor, args: args)
        case .splitClip:     return splitClip(editor, args: args)
        case .generateVideo: return generateVideo(editor, args: args)
        case .generateImage: return generateImage(editor, args: args)
        case .listModels:    return listModels(args: args)
        case .readMedia:     return readMedia(editor, args: args)
        }
    }

    // TODO: Extend read_media for video and audio (AVAsset track metadata, optional waveform via WaveformAnalyzer).
    private func readMedia(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let mediaRef = args["mediaRef"]?.stringValue else {
            return toolError("Missing required argument: mediaRef")
        }
        guard let asset = mediaAsset(id: mediaRef, editor: editor) else {
            return toolError("Media asset not found: \(mediaRef)")
        }
        guard asset.type == .image else {
            return toolError("read_media currently supports only image assets. TODO: video and audio.")
        }

        let url = asset.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            return toolError("Media file not on disk: \(url.lastPathComponent)")
        }

        let maxBytes = args["maxImageBytes"]?.intValue ?? Self.defaultReadImageMaxBytes
        guard maxBytes > 0 else {
            return toolError("maxImageBytes must be positive")
        }

        let fileSize: UInt64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            return toolError("Could not read file attributes: \(error.localizedDescription)")
        }

        guard fileSize <= UInt64(maxBytes) else {
            return toolError("Image file (\(fileSize) bytes) exceeds maxImageBytes (\(maxBytes))")
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return toolError("Failed to read image file")
        }

        let mime = Self.mimeTypeForImagePath(url.path)
        let base64 = data.base64EncodedString()

        var meta: [String: Any] = [
            "mimeType": mime,
            "id": asset.id,
            "name": asset.name,
            "type": asset.type.rawValue,
            "duration": asset.duration,
            "fileName": url.lastPathComponent,
            "byteSize": fileSize,
        ]
        if let w = asset.sourceWidth { meta["sourceWidth"] = w }
        if let h = asset.sourceHeight { meta["sourceHeight"] = h }
        if let fps = asset.sourceFPS { meta["sourceFPS"] = fps }
        meta["generationStatus"] = Self.generationStatusString(asset.generationStatus)
        if let gi = asset.generationInput,
           let encoded = try? JSONEncoder().encode(gi),
           let obj = try? JSONSerialization.jsonObject(with: encoded) {
            meta["generationInput"] = obj
        }
        if let props = Self.imagePropertiesSummary(at: url) {
            meta["imageProperties"] = props
        }

        guard let json = jsonString(meta) else {
            return toolError("Failed to encode metadata")
        }

        return .init(content: [
            .image(data: base64, mimeType: mime, annotations: nil, _meta: nil),
            Self.toolText(json),
        ])
    }

    private func getTimeline(_ editor: EditorViewModel) -> CallTool.Result {
        guard var dict = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(editor.timeline)
        ) as? [String: Any] else {
            return toolError("Failed to encode timeline")
        }
        dict["currentFrame"] = editor.currentFrame
        guard let json = jsonString(dict) else {
            return toolError("Failed to encode timeline")
        }
        return toolOK(json)
    }

    private func getMedia(_ editor: EditorViewModel) -> CallTool.Result {
        guard let data = try? JSONEncoder().encode(editor.mediaManifest),
              let json = String(data: data, encoding: .utf8) else {
            return toolError("Failed to encode media manifest")
        }
        return toolOK(json)
    }

    private func addClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let mediaRef = args["mediaRef"]?.stringValue,
              let trackIndex = args["trackIndex"]?.intValue,
              let startFrame = args["startFrame"]?.intValue,
              let durationFrames = args["durationFrames"]?.intValue else {
            return toolError("Missing required arguments: mediaRef, trackIndex, startFrame, durationFrames")
        }

        guard editor.timeline.tracks.indices.contains(trackIndex) else {
            return toolError("Track index \(trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")
        }

        guard let asset = mediaAsset(id: mediaRef, editor: editor) else {
            return toolError("Media asset not found: \(mediaRef)")
        }

        let clip = Clip(
            mediaRef: mediaRef,
            mediaType: asset.type,
            sourceClipType: asset.type,
            startFrame: startFrame,
            durationFrames: durationFrames
        )
        editor.timeline.tracks[trackIndex].clips.append(clip)
        editor.timeline.tracks[trackIndex].clips.sort { $0.startFrame < $1.startFrame }
        editor.undoManager?.registerUndo(withTarget: editor) { vm in
            vm.removeClips(ids: [clip.id])
        }
        editor.undoManager?.setActionName("Add Clip (MCP)")

        return toolOK("Added clip \(clip.id) to track \(trackIndex) at frame \(startFrame)")
    }

    private func removeClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let clipId = args["clipId"]?.stringValue else {
            return toolError("Missing required argument: clipId")
        }

        guard editor.findClip(id: clipId) != nil else {
            return toolError("Clip not found: \(clipId)")
        }

        editor.removeClips(ids: [clipId])
        return toolOK("Removed clip \(clipId)")
    }

    private func updateClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let clipId = args["clipId"]?.stringValue else {
            return toolError("Missing required argument: clipId")
        }

        guard let loc = editor.findClip(id: clipId) else {
            return toolError("Clip not found: \(clipId)")
        }

        editor.commitClipProperty(clipId: clipId) { clip in
            if let v = args["startFrame"]?.intValue { clip.startFrame = v }
            if let v = args["durationFrames"]?.intValue { clip.durationFrames = v }
            if let v = args["trimStartFrame"]?.intValue { clip.trimStartFrame = v }
            if let v = args["trimEndFrame"]?.intValue { clip.trimEndFrame = v }
            if let v = args["speed"]?.doubleValue { clip.speed = v }
            if let v = args["volume"]?.doubleValue { clip.volume = v }
            if let v = args["opacity"]?.doubleValue { clip.opacity = v }
        }

        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        return toolOK("Updated clip \(clipId): startFrame=\(clip.startFrame), duration=\(clip.durationFrames)")
    }

    private func addTrack(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let typeStr = args["type"]?.stringValue,
              let type = ClipType(rawValue: typeStr) else {
            return toolError("Missing or invalid 'type'. Must be: video, audio, image")
        }
        let label = args["label"]?.stringValue ?? type.trackLabel
        let index = editor.insertTrack(at: editor.timeline.tracks.count, type: type, label: label)
        guard editor.timeline.tracks.indices.contains(index) else {
            return toolError("Failed to add track")
        }
        let track = editor.timeline.tracks[index]
        return toolOK("Added track '\(label)' (type: \(typeStr), id: \(track.id)) at index \(index)")
    }

    private func removeTrack(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let trackId = args["trackId"]?.stringValue else {
            return toolError("Missing required argument: trackId")
        }
        guard editor.timeline.tracks.contains(where: { $0.id == trackId }) else {
            return toolError("Track not found: \(trackId)")
        }
        editor.removeTrack(id: trackId)
        return toolOK("Removed track \(trackId)")
    }

    private func moveClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let clipId = args["clipId"]?.stringValue,
              let toTrack = args["toTrack"]?.intValue,
              let toFrame = args["toFrame"]?.intValue else {
            return toolError("Missing required arguments: clipId, toTrack, toFrame")
        }
        guard editor.findClip(id: clipId) != nil else {
            return toolError("Clip not found: \(clipId)")
        }
        guard editor.timeline.tracks.indices.contains(toTrack) else {
            return toolError("Track index \(toTrack) out of range (0..\(editor.timeline.tracks.count - 1))")
        }
        editor.moveClips([(clipId: clipId, toTrack: toTrack, toFrame: toFrame)])
        return toolOK("Moved clip \(clipId) to track \(toTrack) at frame \(toFrame)")
    }

    private func splitClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let clipId = args["clipId"]?.stringValue,
              let atFrame = args["atFrame"]?.intValue else {
            return toolError("Missing required arguments: clipId, atFrame")
        }
        guard let loc = editor.findClip(id: clipId) else {
            return toolError("Clip not found: \(clipId)")
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard atFrame > clip.startFrame && atFrame < clip.endFrame else {
            return toolError("Frame \(atFrame) is outside clip range (\(clip.startFrame)..\(clip.endFrame))")
        }
        editor.splitClip(clipId: clipId, atFrame: atFrame)
        return toolOK("Split clip \(clipId) at frame \(atFrame)")
    }

    // MARK: - Generation

    private func generateVideo(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let prompt = args["prompt"]?.stringValue, !prompt.isEmpty else {
            return toolError("Missing required argument: prompt")
        }
        guard generationService.hasApiKey else {
            return toolError("No FAL API key configured. Set one in the app's generation panel first.")
        }

        let modelId = args["model"]?.stringValue ?? VideoModelConfig.allModels[0].id
        guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
            let available = VideoModelConfig.allModels.map(\.id).joined(separator: ", ")
            return toolError("Unknown model '\(modelId)'. Available: \(available)")
        }

        let duration = args["duration"]?.intValue ?? model.durations[0]
        let aspectRatio = args["aspectRatio"]?.stringValue ?? model.aspectRatios[0]
        let resolution = args["resolution"]?.stringValue ?? model.resolutions?.first

        var frameRefs: [MediaAsset] = []
        if let startRef = args["startFrameMediaRef"]?.stringValue {
            guard let asset = mediaAsset(id: startRef, editor: editor) else {
                return toolError("Start frame media asset not found: \(startRef)")
            }
            frameRefs.append(asset)
        }
        if let endRef = args["endFrameMediaRef"]?.stringValue {
            guard let asset = mediaAsset(id: endRef, editor: editor) else {
                return toolError("End frame media asset not found: \(endRef)")
            }
            frameRefs.append(asset)
        }

        let genInput = GenerationInput(
            prompt: prompt, model: modelId, duration: duration,
            aspectRatio: aspectRatio, resolution: resolution
        )

        let placeholderId = generationService.generate(
            genInput: genInput,
            assetType: .video,
            placeholderDuration: Double(duration),
            references: frameRefs,
            name: args["name"]?.stringValue,
            buildInput: { uploaded in
                let params = VideoGenerationParams(
                    prompt: prompt, duration: duration,
                    aspectRatio: aspectRatio, resolution: resolution,
                    startFrameURL: uploaded.first,
                    endFrameURL: uploaded.count > 1 ? uploaded[1] : nil,
                    referenceImageURLs: [],
                    generateAudio: true
                )
                return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
            },
            responseKeyPath: { $0["video"]["url"].stringValue },
            fileExtension: "mp4",
            projectURL: editor.projectURL, editor: editor
        )

        return toolOK("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)")
    }

    private func generateImage(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let prompt = args["prompt"]?.stringValue, !prompt.isEmpty else {
            return toolError("Missing required argument: prompt")
        }
        guard generationService.hasApiKey else {
            return toolError("No FAL API key configured. Set one in the app's generation panel first.")
        }

        let modelId = args["model"]?.stringValue ?? ImageModelConfig.allModels[0].id
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            let available = ImageModelConfig.allModels.map(\.id).joined(separator: ", ")
            return toolError("Unknown model '\(modelId)'. Available: \(available)")
        }

        let aspectRatio = args["aspectRatio"]?.stringValue ?? model.aspectRatios[0]
        let resolution = args["resolution"]?.stringValue ?? model.resolutions?.first

        let refs: [MediaAsset] = (args["referenceMediaRefs"]?.arrayValue ?? []).compactMap { refVal in
            guard let refId = refVal.stringValue else { return nil }
            return mediaAsset(id: refId, editor: editor)
        }

        let genInput = GenerationInput(
            prompt: prompt, model: modelId, duration: 0,
            aspectRatio: aspectRatio, resolution: resolution
        )

        let placeholderId = generationService.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: refs,
            name: args["name"]?.stringValue,
            buildInput: { uploaded in
                let input = model.buildInput(
                    prompt: prompt, aspectRatio: aspectRatio,
                    resolution: resolution, imageURLs: uploaded
                )
                return (model.resolvedEndpoint(imageURLs: uploaded), input)
            },
            responseKeyPath: { $0["images"][0]["url"].stringValue },
            fileExtension: "jpg",
            projectURL: editor.projectURL, editor: editor
        )

        return toolOK("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), aspect: \(aspectRatio)")
    }

    private func listModels(args: [String: Value]) -> CallTool.Result {
        let typeFilter = args["type"]?.stringValue
        var result: [[String: Any]] = []

        if typeFilter == nil || typeFilter == "video" {
            result += VideoModelConfig.allModels.map { videoModelInfo($0, includeType: true) }
        }
        if typeFilter == nil || typeFilter == "image" {
            result += ImageModelConfig.allModels.map { imageModelInfo($0, includeType: true) }
        }

        guard let json = jsonString(result) else {
            return toolError("Failed to encode model list")
        }
        return toolOK(json)
    }

    // MARK: - Resources

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

        await server.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self else {
                return .init(contents: [.text("Service unavailable", uri: params.uri)])
            }
            return await self.handleReadResource(params)
        }
    }

    private func handleReadResource(_ params: ReadResource.Parameters) -> ReadResource.Result {
        switch params.uri {
        case "palmier://models/video":
            let json = jsonString(VideoModelConfig.allModels.map { videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: params.uri, mimeType: "application/json")])

        case "palmier://models/image":
            let json = jsonString(ImageModelConfig.allModels.map { imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: params.uri, mimeType: "application/json")])

        default:
            return .init(contents: [.text("Unknown resource: \(params.uri)", uri: params.uri)])
        }
    }

    // MARK: - Prompts

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
                            Generate a video clip\(styleClause).

                            Description: \(desc)

                            Steps:
                            1. Call list_models with type "video" to see available models
                            2. Pick the best model for this use case
                            3. Call generate_video with a detailed prompt based on the description, \
                            the chosen model, duration \(duration)s, and appropriate aspect ratio/resolution
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
                            Generate an image\(styleClause).

                            Description: \(desc)

                            Steps:
                            1. Call list_models with type "image" to see available models
                            2. Pick the best model for this use case
                            3. Call generate_image with a detailed prompt based on the description, \
                            the chosen model, and appropriate aspect ratio/resolution
                            """))
                    ]
                )

            default:
                throw MCPError.invalidRequest("Unknown prompt: \(params.name)")
            }
        }
    }

    // MARK: - Helpers

    private static func mimeTypeForImagePath(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "tiff", "tif": return "image/tiff"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private static func generationStatusString(_ status: MediaAsset.GenerationStatus) -> String {
        switch status {
        case .none: "none"
        case .generating: "generating"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func imagePropertiesSummary(at url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var out: [String: Any] = [:]
        if let v = props[kCGImagePropertyPixelWidth] { out["pixelWidth"] = v }
        if let v = props[kCGImagePropertyPixelHeight] { out["pixelHeight"] = v }
        if let v = props[kCGImagePropertyOrientation] { out["orientation"] = v }
        if let v = props[kCGImagePropertyDepth] { out["depth"] = v }
        if let v = props[kCGImagePropertyColorModel] { out["colorModel"] = v }
        return out.isEmpty ? nil : out
    }

    private static func toolText(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    private static func objectSchema(properties: [String: Value], required: [String]? = nil) -> Value {
        var fields: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if let required {
            fields["required"] = .array(required.map { .string($0) })
        }
        return .object(fields)
    }

    private func toolError(_ message: String) -> CallTool.Result {
        .init(content: [Self.toolText(message)], isError: true)
    }

    private func toolOK(_ message: String) -> CallTool.Result {
        .init(content: [Self.toolText(message)])
    }

    private func mediaAsset(id: String, editor: EditorViewModel) -> MediaAsset? {
        editor.mediaAssets.first { $0.id == id }
    }

    private func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func videoModelInfo(_ m: VideoModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "durations": m.durations, "aspectRatios": m.aspectRatios,
            "supportsFirstFrame": m.supportsFirstFrame,
            "supportsLastFrame": m.supportsLastFrame,
            "supportsReferences": m.supportsReferences,
        ]
        if includeType { info["type"] = "video" }
        if let r = m.resolutions { info["resolutions"] = r }
        if m.maxReferences > 0 { info["maxReferences"] = m.maxReferences }
        return info
    }

    private func imageModelInfo(_ m: ImageModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "aspectRatios": m.aspectRatios,
            "supportsImageReference": m.supportsImageReference,
        ]
        if includeType { info["type"] = "image" }
        if let r = m.resolutions { info["resolutions"] = r }
        return info
    }
}

// MARK: - Value Helpers

private extension Value {
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

}
