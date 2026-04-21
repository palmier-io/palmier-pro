import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
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

struct AgentTool: @unchecked Sendable {
    let name: ToolName
    let description: String
    let inputSchema: [String: Any]
}

enum ToolDefinitions {
    static let all: [AgentTool] = [
        AgentTool(
            name: .getTimeline,
            description: "Always call before any edit. Returns project settings (fps, resolution), track list with types and order, and all clips with their frames and properties. The clipId/trackId values here are what every other tool accepts.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .getMedia,
            description: "Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus (generating | failed | none) for async-generated assets.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .readMedia,
            description: "Visually inspect an image asset — use this before passing it as a reference to generate_video/generate_image so your prompt describes what's actually in the frame rather than guessing from the filename. Returns image content (base64) plus JSON metadata (dimensions, file size, optional EXIF subset). Images only for now; default max 20MB, override via maxImageBytes.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                    "maxImageBytes": ["type": "integer", "description": "Maximum file size in bytes (default 20971520)"],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .addTrack,
            description: "Adds a new track at the bottom of the track list. Track type must match the clips you intend to place on it (video/audio/image). Label is cosmetic.",
            inputSchema: objectSchema(
                properties: [
                    "type": ["type": "string", "enum": ["video", "audio", "image"], "description": "Track type"],
                    "label": ["type": "string", "description": "Display label. Defaults to the type name (e.g. 'Video')."],
                ],
                required: ["type"]
            )
        ),
        AgentTool(
            name: .removeTrack,
            description: "Removes a track and every clip on it. Undoable via the app's undo stack.",
            inputSchema: objectSchema(
                properties: [
                    "trackId": ["type": "string", "description": "The track ID to remove"],
                ],
                required: ["trackId"]
            )
        ),
        AgentTool(
            name: .addClip,
            description: "Places a media asset on an existing track at startFrame for durationFrames. The asset's type must be compatible with the track's type (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). Call get_timeline first to pick a valid trackIndex and an open frame range.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                    "trackIndex": ["type": "integer", "description": "Track index (0-based)"],
                    "startFrame": ["type": "integer", "description": "Frame position to place the clip"],
                    "durationFrames": ["type": "integer", "description": "Duration in frames"],
                ],
                required: ["mediaRef", "trackIndex", "startFrame", "durationFrames"]
            )
        ),
        AgentTool(
            name: .removeClip,
            description: "Removes a clip by ID. If the clip belongs to a link group (e.g. a video with its paired audio), every clip in that group is removed together — matching the UI's linked-delete behavior. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID to remove"],
                ],
                required: ["clipId"]
            )
        ),
        AgentTool(
            name: .updateClip,
            description: "Changes an existing clip's position, trim, speed, volume, or opacity. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. Omit fields to leave them unchanged.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID to update"],
                    "startFrame": ["type": "integer", "description": "New start frame position"],
                    "durationFrames": ["type": "integer", "description": "New duration in frames"],
                    "trimStartFrame": ["type": "integer", "description": "Frames to trim from start of source"],
                    "trimEndFrame": ["type": "integer", "description": "Frames to trim from end of source"],
                    "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0)"],
                    "volume": ["type": "number", "description": "Volume 0.0-1.0 (default 1.0)"],
                    "opacity": ["type": "number", "description": "Opacity 0.0-1.0 (default 1.0)"],
                ],
                required: ["clipId"]
            )
        ),
        AgentTool(
            name: .moveClip,
            description: "Moves a clip to a new track and/or frame. Overlap with existing clips on the destination track is resolved automatically.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID to move"],
                    "toTrack": ["type": "integer", "description": "Destination track index (0-based)"],
                    "toFrame": ["type": "integer", "description": "Destination frame position"],
                ],
                required: ["clipId", "toTrack", "toFrame"]
            )
        ),
        AgentTool(
            name: .splitClip,
            description: "Splits a clip into two at atFrame. The frame must be strictly between the clip's start and end — use get_timeline to confirm the range.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID to split"],
                    "atFrame": ["type": "integer", "description": "Frame position to split at (must be between clip start and end)"],
                ],
                required: ["clipId", "atFrame"]
            )
        ),
        AgentTool(
            name: .generateVideo,
            description: "Starts an async AI video generation. Returns a placeholder asset ID immediately; generation runs in the background and the asset becomes usable in add_clip once ready. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Text description of the video to generate"],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'veo3.1-fast'). Use list_models to see options. Defaults to first available model."],
                    "duration": ["type": "integer", "description": "Duration in seconds. Valid values depend on model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16', '1:1')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '720p', '1080p', '4k')"],
                    "startFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the first frame (image-to-video)"],
                    "endFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the last frame (supported by some models)"],
                    "sourceVideoMediaRef": ["type": "string", "description": "Media asset ID of a source video (required by video-to-video edit models; ignores duration/aspectRatio/resolution)"],
                    "referenceImageMediaRef": ["type": "string", "description": "Media asset ID of a reference image (video-to-video edit models that support references)"],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .generateImage,
            description: "Starts an async AI image generation. Returns a placeholder asset ID immediately; generation runs in the background. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Text description of the image to generate"],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'nano-banana-pro'). Use list_models to see options. Defaults to first available model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '2K', '4K')"],
                    "referenceMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs to use as reference images"],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .listModels,
            description: "Lists AI models with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support). Always call before generate_video or generate_image so the model you pick actually supports the constraints you need.",
            inputSchema: objectSchema(
                properties: [
                    "type": ["type": "string", "enum": ["video", "image"], "description": "Filter by type. Omit to list all models."],
                ]
            )
        ),
    ]

    private static func objectSchema(
        properties: [String: [String: Any]] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var dict: [String: Any] = ["type": "object"]
        if !properties.isEmpty {
            dict["properties"] = properties
        }
        if !required.isEmpty {
            dict["required"] = required
        }
        return dict
    }
}

extension AgentTool {
    var mcpSchemaValue: Value {
        Self.valueFromJSON(inputSchema)
    }

    private static func valueFromJSON(_ any: Any) -> Value {
        switch any {
        case let v as Value: return v
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let arr as [Any]: return .array(arr.map(valueFromJSON))
        case let dict as [String: Any]:
            var out: [String: Value] = [:]
            for (k, v) in dict { out[k] = valueFromJSON(v) }
            return .object(out)
        default: return .null
        }
    }
}

enum ToolArgsBridge {
    static func argsFromMCP(_ args: [String: Value]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in args { out[k] = anyFromValue(v) }
        return out
    }

    static func anyFromValue(_ v: Value) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let d): return d
        case .array(let arr): return arr.map(anyFromValue)
        case .object(let obj):
            var out: [String: Any] = [:]
            for (k, v) in obj { out[k] = anyFromValue(v) }
            return out
        }
    }
}
