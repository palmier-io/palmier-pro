import Foundation
import ImageIO
import MCP

/// MCP server exposing editor tools over HTTP on localhost:19789.
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    nonisolated private static let serverInstructions = """
        You are a creative AI assistant connected to palmier-pro, a AI-native video editor. Your job is \
        to help the user create and edit a video project by calling the tools exposed by this \
        MCP server.

        # Core model
        - The project is a timeline with a fixed fps (e.g. 30) and a resolution. All timing is in \
          frames, not seconds. Convert from user-facing seconds via frame = seconds × fps.
        - The timeline has ordered tracks. Each track has a type (video/audio/image) and holds clips.
        - A clip references a media asset and occupies [startFrame, startFrame + durationFrames) \
          on its track.
        - Clips have trimStartFrame / trimEndFrame (offsets into the source media, not the \
          timeline), speed, volume, and opacity.
        - Media assets live in a project-level library and are referenced by ID. Assets may be \
          user-imported or AI-generated.

        # Always do
        - Call get_timeline before any edit so you know fps, the track list and types, and \
          existing clip frames.
        - Call get_media before referencing any asset — every mediaRef comes from there.
        - Call list_models before generate_video or generate_image so the model you pick actually \
          supports your duration, aspect ratio, and first/last-frame or reference needs.
        - When passing an existing asset as a reference (startFrameMediaRef, endFrameMediaRef, \
          referenceMediaRefs), call read_media on it first and describe what's actually in the \
          frame. Never guess from the filename.

        # Editing discipline
        - Placements must fit the track's type: video clips on video tracks, etc.
        - update_clip: omit fields to leave them unchanged. speed 1.0 is normal; <1.0 stretches \
          the clip longer on the timeline; >1.0 shortens it. trim* values are source offsets.
        - split_clip's atFrame must be strictly between the clip's start and end.
        - Timeline edits are undoable via the app's undo stack and are effectively free — don't \
          ask permission for individual edits, just explain what you changed.

        # Generation discipline
        - Default flow: images first, then video. Iterate on images with the user until they \
          approve the look, then use the approved image as the video's startFrameMediaRef. \
          Go straight to text-to-video only if the user explicitly asks or the shot has no \
          single anchorable frame (e.g. a continuous camera sweep starting from black).
        - Generation is asynchronous and costs real money. Propose the prompt, chosen model, \
          duration, and aspect ratio to the user and wait for confirmation before calling \
          generate_video or generate_image.
        - Both tools return a placeholder asset ID immediately. The asset appears in get_media \
          with generationStatus: "generating". Poll get_media until the status clears; then the \
          asset is drop-in usable in add_clip.
        - Video models cannot render readable text. For on-screen text, generate a still via \
          generate_image (text baked into the image) and pass it as startFrameMediaRef.
        - For character / location / style consistency across multiple generations, reuse \
          references: referenceMediaRefs for images, startFrameMediaRef / endFrameMediaRef for \
          videos.
        - Parallelize independent image generations. Build base images (characters, locations) \
          before derived ones (same character in scene 3).

        # Prompt craft
        - Images (nano-banana-pro, nano-banana-2, recraft-v4): 15–30 words. Formula: subject + \
          setting + shot type + lighting/mood. Concrete nouns beat adjectives. grok-imagine \
          prefers a natural-language sentence with looser style.
        - Videos (veo3.1 family, kling-v3/o3, seedance-2, minimax-hailuo-2.3, ltx-2.3, \
          grok-imagine-video): 8–20 words. Formula: camera movement + subject action. When the \
          video has a startFrameMediaRef, do not re-describe what's in that frame — the model \
          already sees it; spend the prompt on motion and sound.
        - Audio in video prompts: state dialogue, VO, SFX, and music explicitly (tone, volume, \
          pitch when persistent). Silent video is usually a bug, not a feature.
        - Image the user supplies (via referenceMediaRefs, startFrameMediaRef, etc.) is the \
          source of truth for what's in the frame. Always read_media it and describe what you \
          actually see; never paraphrase the filename.
        - Never generate: UI screenshots, app interfaces, software screens, logo animations, \
          motion graphics, title cards, text overlays, or screen recordings. Those belong in \
          the editor (add_clip with an imported asset), not in the model.

        # Communication
        - Be concise. Describe what you did and what's next, not the mechanics of each tool call.
        - When the user is vague about aesthetic direction, ask one focused question instead of \
          guessing.
        """

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
                instructions: Self.serverInstructions,
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
                description: "Always call before any edit. Returns project settings (fps, resolution), track list with types and order, and all clips with their frames and properties. The clipId/trackId values here are what every other tool accepts.",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: ToolName.getMedia.rawValue,
                description: "Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus for async-generated assets — poll this to know when a generation is done.",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: ToolName.readMedia.rawValue,
                description: "Visually inspect an image asset — use this before passing it as a reference to generate_video/generate_image so your prompt describes what's actually in the frame rather than guessing from the filename. Returns MCP image content (base64) plus JSON metadata (dimensions, file size, optional EXIF subset). Images only for now; default max 20MB, override via maxImageBytes.",
                inputSchema: Self.objectSchema(properties: [
                    "mediaRef": .object(["type": .string("string"), "description": .string("ID of the media asset from get_media")]),
                    "maxImageBytes": .object(["type": .string("integer"), "description": .string("Maximum file size in bytes (default 20971520)")]),
                ], required: ["mediaRef"])
            ),
            Tool(
                name: ToolName.addTrack.rawValue,
                description: "Adds a new track at the bottom of the track list. Track type must match the clips you intend to place on it (video/audio/image). Label is cosmetic.",
                inputSchema: Self.objectSchema(properties: [
                    "type": .object(["type": .string("string"), "enum": .array([.string("video"), .string("audio"), .string("image")]), "description": .string("Track type")]),
                    "label": .object(["type": .string("string"), "description": .string("Display label. Defaults to the type name (e.g. 'Video').")]),
                ], required: ["type"])
            ),
            Tool(
                name: ToolName.removeTrack.rawValue,
                description: "Removes a track and every clip on it. Undoable via the app's undo stack.",
                inputSchema: Self.objectSchema(properties: [
                    "trackId": .object(["type": .string("string"), "description": .string("The track ID to remove")]),
                ], required: ["trackId"])
            ),
            Tool(
                name: ToolName.addClip.rawValue,
                description: "Places a media asset on an existing track at startFrame for durationFrames. The asset's type must be compatible with the track's type. Call get_timeline first to pick a valid trackIndex and an open frame range.",
                inputSchema: Self.objectSchema(properties: [
                    "mediaRef": .object(["type": .string("string"), "description": .string("ID of the media asset from get_media")]),
                    "trackIndex": .object(["type": .string("integer"), "description": .string("Track index (0-based)")]),
                    "startFrame": .object(["type": .string("integer"), "description": .string("Frame position to place the clip")]),
                    "durationFrames": .object(["type": .string("integer"), "description": .string("Duration in frames")]),
                ], required: ["mediaRef", "trackIndex", "startFrame", "durationFrames"])
            ),
            Tool(
                name: ToolName.removeClip.rawValue,
                description: "Removes one clip by ID. Undoable.",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to remove")]),
                ], required: ["clipId"])
            ),
            Tool(
                name: ToolName.updateClip.rawValue,
                description: "Changes an existing clip's position, trim, speed, volume, or opacity. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. Omit fields to leave them unchanged.",
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
                description: "Moves a clip to a new track and/or frame. Overlap with existing clips on the destination track is resolved automatically.",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to move")]),
                    "toTrack": .object(["type": .string("integer"), "description": .string("Destination track index (0-based)")]),
                    "toFrame": .object(["type": .string("integer"), "description": .string("Destination frame position")]),
                ], required: ["clipId", "toTrack", "toFrame"])
            ),
            Tool(
                name: ToolName.splitClip.rawValue,
                description: "Splits a clip into two at atFrame. The frame must be strictly between the clip's start and end — use get_timeline to confirm the range.",
                inputSchema: Self.objectSchema(properties: [
                    "clipId": .object(["type": .string("string"), "description": .string("The clip ID to split")]),
                    "atFrame": .object(["type": .string("integer"), "description": .string("Frame position to split at (must be between clip start and end)")]),
                ], required: ["clipId", "atFrame"])
            ),
            Tool(
                name: ToolName.generateVideo.rawValue,
                description: "Starts an async AI video generation. Returns a placeholder asset ID immediately; the asset's generationStatus in get_media goes from 'generating' to 'none' when ready, then it is drop-in usable in add_clip. Always call list_models first to pick a model whose durations, aspectRatios, and supportsFirstFrame/supportsLastFrame fit your needs. Video models cannot render readable text — if you need on-screen text, bake it into a still via generate_image and pass it as startFrameMediaRef. Costs real money and is not undoable; get user confirmation before calling.",
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
                description: "Starts an async AI image generation. Returns a placeholder asset ID immediately; poll generationStatus via get_media for completion. Call list_models first to pick a model. Pass existing media IDs via referenceMediaRefs for character/style/location consistency across generations. Costs real money and is not undoable; get user confirmation before calling.",
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
                description: "Lists AI models with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support). Always call before generate_video or generate_image so the model you pick actually supports the constraints you need.",
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
