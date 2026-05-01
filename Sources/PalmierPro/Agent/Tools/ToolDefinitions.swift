import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
    case getTimeline = "get_timeline"
    case getMedia = "get_media"
    case addTrack = "add_track"
    case removeTrack = "remove_track"
    case addClips = "add_clips"
    case removeClips = "remove_clips"
    case updateClips = "update_clips"
    case moveClip = "move_clip"
    case splitClip = "split_clip"
    case addTexts = "add_texts"
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
            description: "Inspect a media asset. Images: returns the image plus dimensions, file size, and EXIF subset (raise maxImageBytes past 20MB if the user needs a larger source). Videos: returns evenly-spaced sample frames with timestamps (default 6, cap 12 via maxFrames), and a transcription of the audio track when available. Audio: returns a transcription with full text, language, and per-word timestamps (with speakerId when multiple speakers are detected). Call before referencing an asset so your description matches reality, or to plan splits/trims on dialogue boundaries.\n\nFor captioning, pass clipId alongside mediaRef: each word gains timelineStartFrame/timelineEndFrame mapped through that clip's startFrame, trimStartFrame, and speed. Feed those frames straight into add_texts — no manual math, no drift from trim or offset.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                    "clipId": ["type": "string", "description": "Optional. When provided, the clip must reference the given mediaRef. Each transcription word is enriched with timelineStartFrame/timelineEndFrame computed from the clip's timeline position, trim, and speed. Words outside the visible trim window are omitted from the timeline fields."],
                    "maxImageBytes": ["type": "integer", "description": "Image only. Maximum file size in bytes (default 20971520)."],
                    "maxFrames": ["type": "integer", "description": "Video only. Number of sample frames to return (default 6, cap 12)."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .addTrack,
            description: "Adds a new track at the top of its zone — visual tracks (video/image) insert at index 0; audio tracks insert at the top of the audio zone (just below the visual tracks). Track type must match the clips you intend to place on it (video/audio/image). Label is cosmetic.",
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
            name: .addClips,
            description: "Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). Call get_timeline first to pick valid trackIndex values and open frame ranges. The whole batch is one undo step.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Clips to add. Each entry is validated up front; one bad entry rejects the whole call with no partial state.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                                "trackIndex": ["type": "integer", "description": "Track index (0-based)"],
                                "startFrame": ["type": "integer", "description": "Frame position to place the clip"],
                                "durationFrames": ["type": "integer", "description": "Duration in frames"],
                            ],
                            "required": ["mediaRef", "trackIndex", "startFrame", "durationFrames"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .removeClips,
            description: "Removes one or more clips by ID as a single undoable action. Any clip that belongs to a link group (e.g. a video with its paired audio) takes its whole group with it, matching the UI's linked-delete behavior.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to remove.",
                        "items": ["type": "string"],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .updateClips,
            description: "Updates one or more existing clips (timing, trim, speed, volume, opacity, transform) as a single undoable action. Handles every clip type — text clips also accept content and style fields (content, fontName, fontSize, color, alignment). trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. transform uses 0–1 normalized canvas coords, partial merge (pass only centerY to reposition vertically). When a text clip's content or font changes without an explicit transform, the bounding box auto-refits. Per-update, omit fields to leave them unchanged. Text-only fields on non-text clips are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "updates": [
                        "type": "array",
                        "description": "Per-clip partial updates. Each entry requires clipId; all other fields are optional. Unknown fields are rejected.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "clipId": ["type": "string", "description": "The clip ID to update"],
                                "startFrame": ["type": "integer", "description": "New start frame position"],
                                "durationFrames": ["type": "integer", "description": "New duration in frames"],
                                "trimStartFrame": ["type": "integer", "description": "Frames to trim from start of source"],
                                "trimEndFrame": ["type": "integer", "description": "Frames to trim from end of source"],
                                "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0)"],
                                "volume": ["type": "number", "description": "Volume 0.0-1.0 (default 1.0)"],
                                "opacity": ["type": "number", "description": "Opacity 0.0-1.0 (default 1.0)"],
                                "transform": [
                                    "type": "object",
                                    "description": "Partial transform. Any combination of centerX, centerY, width, height; omitted fields keep their current value.",
                                    "properties": [
                                        "centerX": ["type": "number"],
                                        "centerY": ["type": "number"],
                                        "width": ["type": "number"],
                                        "height": ["type": "number"],
                                    ],
                                ],
                                "content": ["type": "string", "description": "Text clips only. New text content."],
                                "fontName": ["type": "string", "description": "Text clips only. Font PostScript or family name."],
                                "fontSize": ["type": "number", "description": "Text clips only. Font size in canvas points."],
                                "color": ["type": "string", "description": "Text clips only. Hex '#RRGGBB' or '#RRGGBBAA'."],
                                "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text clips only."],
                            ],
                            "required": ["clipId"],
                        ],
                    ],
                ],
                required: ["updates"]
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
            name: .addTexts,
            description: "Adds one or more text clips (titles, captions, lower-thirds) in a single undoable action. Text renders as an overlay on top of visual media. Transform uses 0–1 normalized canvas coords: (0.5,0.5) is center, (0.5,0.1) top-center, (0.5,0.9) bottom-center. Omit transform to center + auto-fit. Pass only centerX/centerY to reposition with auto-fit size (common for lower-thirds). Pass all four fields to override the box entirely. Colors are hex '#RRGGBB' or '#RRGGBBAA'.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates one new video track at the top and places all text clips there — the common case for captions. To target existing tracks, set trackIndex on every entry (audio tracks rejected). Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing (or earlier-batch) clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior. To show multiple text clips at the same time (stacked titles, simultaneous labels), put each on a DIFFERENT trackIndex so they layer instead of trimming each other.\n\nCaptioning workflow: call read_media with both mediaRef AND clipId for the audio clip — each transcription word comes back with timelineStartFrame/timelineEndFrame already mapped through the clip's position, trim, and speed. Build phrases of 3–6 words; set startFrame to the first word's timelineStartFrame and durationFrames to (last word's timelineEndFrame - first word's timelineStartFrame). Omit trackIndex on every entry so all captions land on one auto-created track. Unknown fields are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Text clips to add. Each entry is independent.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "trackIndex": ["type": "integer", "description": "Optional. Track index (0-based) for an existing non-audio track. Omit on every entry to auto-create one new track for the batch."],
                                "startFrame": ["type": "integer", "description": "Frame position to place the clip"],
                                "durationFrames": ["type": "integer", "description": "Duration in frames (>= 1)"],
                                "content": ["type": "string", "description": "Text to display. Supports \\n for line breaks."],
                                "transform": [
                                    "type": "object",
                                    "description": "Optional position/size. Omit for center + auto-fit. Pass centerX+centerY only for a specific position with auto-fit size. Pass all four for full override.",
                                    "properties": [
                                        "centerX": ["type": "number", "description": "Horizontal center 0–1 (0=left edge, 1=right edge)"],
                                        "centerY": ["type": "number", "description": "Vertical center 0–1 (0=top, 1=bottom)"],
                                        "width": ["type": "number", "description": "Width 0–1 (optional; omit for auto-fit)"],
                                        "height": ["type": "number", "description": "Height 0–1 (optional; omit for auto-fit)"],
                                    ],
                                ],
                                "fontName": ["type": "string", "description": "Font PostScript or family name, e.g. 'Helvetica-Bold', 'Georgia-Bold'. Default 'Helvetica-Bold'. Falls back to bold system font if not found."],
                                "fontSize": ["type": "number", "description": "Font size in canvas points (default 96). On a 1080p canvas ~50 is a caption, ~120 is a title."],
                                "color": ["type": "string", "description": "Hex '#RRGGBB' or '#RRGGBBAA' (default '#FFFFFF')"],
                                "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text alignment (default 'center')"],
                            ],
                            "required": ["startFrame", "durationFrames", "content"],
                        ],
                    ],
                ],
                required: ["entries"]
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
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of image references. Covers both reference-to-video generation (Seedance, Kling V3/O3 elements, Grok — refer as @Image1/@Element1 in prompt) and the single-image ref used by video-to-video edit models (Kling V3 Motion Control). See list_models maxReferenceImages for per-model cap."],
                    "referenceVideoMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of video references (Seedance only). Refer to them as @Video1, @Video2. See maxReferenceVideos and maxCombinedVideoRefSeconds."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of audio references (Seedance only). Refer to them as @Audio1, @Audio2. See maxReferenceAudios and maxCombinedAudioRefSeconds."],
                    "groupWithMediaRef": ["type": "string", "description": "Optional. If set, the result joins this asset's variant stack instead of starting a new one. Use any asset id from the stack — the root is resolved automatically. Type must match (video). Useful for grouping multiple related generations of the same shot."],
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
                    "quality": ["type": "string", "description": "Image quality (e.g. 'low', 'medium', 'high'). Only supported by some models — see list_models."],
                    "referenceMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs to use as reference images"],
                    "groupWithMediaRef": ["type": "string", "description": "Optional. If set, the result joins this asset's variant stack instead of starting a new one. Use any asset id from the stack — the root is resolved automatically. Type must match (image)."],
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
                    "groupWithMediaRef": ["type": "string", "description": "Optional. If set, the result joins this asset's variant stack instead of starting a new one. Use any asset id from the stack — the root is resolved automatically. Type must match (audio)."],
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
