import Foundation
import MCP

/// MCP server exposing editor tools over HTTP on localhost:19789.
@MainActor
final class MCPService {

    static let port: UInt16 = 19789

    private weak var editor: EditorViewModel?
    private var httpServer: MCPHTTPServer?

    init(editor: EditorViewModel) {
        self.editor = editor
    }

    func start() {
        let httpServer = MCPHTTPServer(port: Self.port) { [weak self] in
            let server = Server(
                name: "palmier-pro",
                version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: false))
            )
            await self?.registerTools(on: server)
            return server
        }
        self.httpServer = httpServer
        Task { try await httpServer.start() }
    }

    func stop() {
        if let server = httpServer {
            Task { await server.stop() }
        }
        httpServer = nil
    }

    // MARK: - Tools

    private func registerTools(on server: Server) async {
        let noArgsSchema = Value.object(["type": .string("object")])
        let tools = [
            Tool(
                name: "get_project_info",
                description: "Get project settings (fps, resolution)",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: "get_timeline",
                description: "Get the full timeline with all tracks and clips",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: "get_media",
                description: "List all available media assets in the project",
                inputSchema: noArgsSchema
            ),
            Tool(
                name: "add_clip",
                description: "Add a media asset as a clip on a track",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mediaRef": .object(["type": .string("string"), "description": .string("ID of the media asset from get_media")]),
                        "trackIndex": .object(["type": .string("integer"), "description": .string("Track index (0-based)")]),
                        "startFrame": .object(["type": .string("integer"), "description": .string("Frame position to place the clip")]),
                        "durationFrames": .object(["type": .string("integer"), "description": .string("Duration in frames")]),
                    ]),
                    "required": .array([.string("mediaRef"), .string("trackIndex"), .string("startFrame"), .string("durationFrames")]),
                ])
            ),
            Tool(
                name: "remove_clip",
                description: "Remove a clip from the timeline by its ID",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clipId": .object(["type": .string("string"), "description": .string("The clip ID to remove")]),
                    ]),
                    "required": .array([.string("clipId")]),
                ])
            ),
            Tool(
                name: "update_clip",
                description: "Update properties of an existing clip",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clipId": .object(["type": .string("string"), "description": .string("The clip ID to update")]),
                        "startFrame": .object(["type": .string("integer"), "description": .string("New start frame position")]),
                        "durationFrames": .object(["type": .string("integer"), "description": .string("New duration in frames")]),
                        "trimStartFrame": .object(["type": .string("integer"), "description": .string("Frames to trim from start")]),
                        "trimEndFrame": .object(["type": .string("integer"), "description": .string("Frames to trim from end")]),
                        "speed": .object(["type": .string("number"), "description": .string("Playback speed multiplier")]),
                        "volume": .object(["type": .string("number"), "description": .string("Volume (0.0 to 1.0)")]),
                        "opacity": .object(["type": .string("number"), "description": .string("Opacity (0.0 to 1.0)")]),
                    ]),
                    "required": .array([.string("clipId")]),
                ])
            ),
        ]

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        let unavailable = CallTool.Result(content: [Self.toolText("Editor not available")], isError: true)
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            await self?.handleToolCall(params) ?? unavailable
        }
    }

    // MARK: - Handlers

    private func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let editor else {
            return .init(content: [Self.toolText("Editor not available")], isError: true)
        }

        let args = params.arguments ?? [:]
        switch params.name {
        case "get_project_info": return getProjectInfo(editor)
        case "get_timeline":     return getTimeline(editor)
        case "get_media":        return getMedia(editor)
        case "add_clip":         return addClip(editor, args: args)
        case "remove_clip":      return removeClip(editor, args: args)
        case "update_clip":      return updateClip(editor, args: args)
        default:
            return .init(content: [Self.toolText("Unknown tool: \(params.name)")], isError: true)
        }
    }

    private func getProjectInfo(_ editor: EditorViewModel) -> CallTool.Result {
        let info: [String: Any] = [
            "fps": editor.timeline.fps,
            "width": editor.timeline.width,
            "height": editor.timeline.height,
            "totalFrames": editor.timeline.totalFrames,
            "currentFrame": editor.currentFrame,
            "trackCount": editor.timeline.tracks.count,
        ]
        return jsonResult(info)
    }

    private func getTimeline(_ editor: EditorViewModel) -> CallTool.Result {
        guard let data = try? JSONEncoder().encode(editor.timeline),
              let json = String(data: data, encoding: .utf8) else {
            return .init(content: [Self.toolText("Failed to encode timeline")], isError: true)
        }
        return .init(content: [Self.toolText(json)])
    }

    private func getMedia(_ editor: EditorViewModel) -> CallTool.Result {
        guard let data = try? JSONEncoder().encode(editor.mediaManifest),
              let json = String(data: data, encoding: .utf8) else {
            return .init(content: [Self.toolText("Failed to encode media manifest")], isError: true)
        }
        return .init(content: [Self.toolText(json)])
    }

    private func addClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let mediaRef = args["mediaRef"]?.stringValue,
              let trackIndex = args["trackIndex"]?.intValue,
              let startFrame = args["startFrame"]?.intValue,
              let durationFrames = args["durationFrames"]?.intValue else {
            return .init(content: [Self.toolText("Missing required arguments: mediaRef, trackIndex, startFrame, durationFrames")], isError: true)
        }

        guard editor.timeline.tracks.indices.contains(trackIndex) else {
            return .init(content: [Self.toolText("Track index \(trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")], isError: true)
        }

        guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
            return .init(content: [Self.toolText("Media asset not found: \(mediaRef)")], isError: true)
        }

        let clip = Clip(
            mediaRef: mediaRef,
            mediaType: asset.type,
            startFrame: startFrame,
            durationFrames: durationFrames
        )
        editor.timeline.tracks[trackIndex].clips.append(clip)
        editor.timeline.tracks[trackIndex].clips.sort { $0.startFrame < $1.startFrame }
        editor.undoManager?.registerUndo(withTarget: editor) { vm in
            vm.removeClips(ids: [clip.id])
        }
        editor.undoManager?.setActionName("Add Clip (MCP)")

        return .init(content: [Self.toolText("Added clip \(clip.id) to track \(trackIndex) at frame \(startFrame)")])
    }

    private func removeClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let clipId = args["clipId"]?.stringValue else {
            return .init(content: [Self.toolText("Missing required argument: clipId")], isError: true)
        }

        guard editor.findClip(id: clipId) != nil else {
            return .init(content: [Self.toolText("Clip not found: \(clipId)")], isError: true)
        }

        editor.removeClips(ids: [clipId])
        return .init(content: [Self.toolText("Removed clip \(clipId)")])
    }

    private func updateClip(_ editor: EditorViewModel, args: [String: Value]) -> CallTool.Result {
        guard let clipId = args["clipId"]?.stringValue else {
            return .init(content: [Self.toolText("Missing required argument: clipId")], isError: true)
        }

        guard let loc = editor.findClip(id: clipId) else {
            return .init(content: [Self.toolText("Clip not found: \(clipId)")], isError: true)
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
        return .init(content: [Self.toolText("Updated clip \(clipId): startFrame=\(clip.startFrame), duration=\(clip.durationFrames)")])
    }

    // MARK: - Helpers

    private static func toolText(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    private func jsonResult(_ dict: [String: Any]) -> CallTool.Result {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else {
            return .init(content: [Self.toolText("{}")], isError: true)
        }
        return .init(content: [Self.toolText(json)])
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

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        default: return nil
        }
    }
}
