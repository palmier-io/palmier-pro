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
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"
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
            description: "Always call at the start of a session. Returns project settings (fps, resolution), track list with types and order, all clips with their frames and properties, and hasFalApiKey (if false, generation/transcription/upscale tools will fail — warn the user to configure the key in the app's generation panel before attempting them). The clipId/trackId values here are what every other tool accepts.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .getMedia,
            description: "Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus (generating | failed | none) for async-generated assets.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .readMedia,
            description: "Inspect a media asset's content. Images: returns the image (base64) plus metadata (dimensions, file size, EXIF subset); default max 20MB, override via maxImageBytes. Videos: returns evenly-spaced sample frames as JPEGs plus metadata with frame timestamps; default 6 frames, override via maxFrames (cap 12). If the video has an audio track and a FAL API key is configured, the audio track is auto-extracted and transcribed; the transcription nests under the \"transcription\" key (or \"transcriptionError\" if it fails — frames still return). Audio: transcribes the file via fal-ai/elevenlabs/speech-to-text/scribe-v2 and returns JSON with full text, detected language, and per-word entries (each with start/end timestamps, type = word | audio_event, and speakerId when diarization applies) — requires FAL API key. Call before passing an asset as a reference so your prompt describes what's actually there, or to plan splits/trims on dialogue boundaries.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                    "maxImageBytes": ["type": "integer", "description": "Image only. Maximum file size in bytes (default 20971520)."],
                    "maxFrames": ["type": "integer", "description": "Video only. Number of sample frames to return (default 6, cap 12)."],
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
            name: .generateAudio,
            description: "Starts an async AI audio generation (text-to-speech or music). Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clip once ready. TTS models (elevenlabs-tts-v3, gemini-3.1-flash-tts) convert the prompt into speech and accept a 'voice' name. Music models (minimax-music-v2.6, elevenlabs-music) generate background tracks; pass 'lyrics' for MiniMax vocals or set 'instrumental' true for either music model. Only elevenlabs-music accepts 'duration'. Use list_models with type='audio' to see voices/capabilities. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "TTS: the text to speak. Music: a description of the style, mood, genre, or scenario. MiniMax requires ≥10 chars."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID. Use list_models with type='audio' to see options. Defaults to the first model."],
                    "voice": ["type": "string", "description": "TTS only. Voice preset name. list_models shows voicesSample (first 3) + voiceCount; any voice supported by the model is accepted. Defaults to the model's defaultVoice. Ignored by music models."],
                    "lyrics": ["type": "string", "description": "MiniMax Music only. Lyrics with optional [Verse]/[Chorus] section tags. If omitted and instrumental=false, MiniMax auto-writes lyrics from the prompt."],
                    "styleInstructions": ["type": "string", "description": "Gemini TTS only. Optional delivery instructions (e.g. 'warm and slow', 'British accent')."],
                    "instrumental": ["type": "boolean", "description": "Music models only. true = no vocals. Defaults to false."],
                    "duration": ["type": "integer", "description": "ElevenLabs Music only. Length in seconds (3–600). Ignored by other models."],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .upscaleMedia,
            description: "Upscales an existing video or image asset to higher resolution using an AI upscaler. Returns a placeholder asset ID immediately; the upscaled asset appears in get_media once ready. Use list_models with type='upscale' to pick a model that supports the asset's type. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the video or image asset to upscale"],
                    "model": ["type": "string", "description": "Upscaler model ID (e.g. 'bytedance-upscaler', 'seedvr-image-upscaler'). Defaults to the first model that supports the asset's type."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .listModels,
            description: "Lists AI models with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support, voices/category for audio, upscaler speed). Always call before generate_video, generate_image, generate_audio, or upscale_media so the model you pick actually supports the constraints you need.",
            inputSchema: objectSchema(
                properties: [
                    "type": ["type": "string", "enum": ["video", "image", "audio", "upscale"], "description": "Filter by type. Omit to list all models."],
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
