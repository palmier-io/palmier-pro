import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
    case getTimeline = "get_timeline"
    case getMedia = "get_media"
    case addClips = "add_clips"
    case removeClips = "remove_clips"
    case moveClips = "move_clips"
    case setClipProperties = "set_clip_properties"
    case setKeyframes = "set_keyframes"
    case splitClip = "split_clip"
    case addTexts = "add_texts"
    case addCaptions = "add_captions"
    case generateVideo = "generate_video"
    case generateImage = "generate_image"
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"
    case importMedia = "import_media"
    case listModels = "list_models"
    case inspectMedia = "inspect_media"
    case listFolders = "list_folders"
    case createFolder = "create_folder"
    case moveToFolder = "move_to_folder"
    case renameMedia = "rename_media"
    case renameFolder = "rename_folder"
    case deleteMedia = "delete_media"
    case deleteFolder = "delete_folder"
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
            description: "Always call at the start of a session. Returns project settings (fps, resolution), track list with types and order, all clips with their frames and properties, and canGenerate (if false, generation/upscale tools will fail — tell the user to sign in to Palmier and subscribe before attempting them). The clipId/trackId values here are what every other tool accepts.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .getMedia,
            description: "Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus (generating | downloading | failed | none) for async-generated and -imported assets.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .inspectMedia,
            description: "Inspect a media asset. Images: returns the image plus dimensions, file size, and EXIF subset (raise maxImageBytes past 20MB if the user needs a larger source). Videos: returns evenly-spaced sample frames with timestamps (default 6, cap 12 via maxFrames), and a transcription of the audio track when available. Audio: returns a transcription with full text, language, and per-word timestamps. Call before referencing an asset so your description matches reality, or to plan splits/trims on dialogue boundaries.\n\nTranscription: text is the full transcript; words is [text, start, end] tuples. wordTiming names the units — source seconds, or project frames when clipId is passed (pass clipId for captioning; out-of-range words are dropped).",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                    "clipId": ["type": "string", "description": "Optional. Must reference the given mediaRef. Word timings then come back as project frames for this clip ([text, startFrame, endFrame]) instead of source seconds."],
                    "maxImageBytes": ["type": "integer", "description": "Image only. Maximum file size in bytes (default 20971520)."],
                    "maxFrames": ["type": "integer", "description": "Video only. Number of sample frames to return (default 6, cap 12)."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .addClips,
            description: "Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). The whole batch is one undo step.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates the needed tracks — one shared video track for visual entries and one shared audio track for audio entries (matches the captioning pattern in add_texts). To target existing tracks, set trackIndex on every entry. Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Clips to add. Each entry is validated up front; one bad entry rejects the whole call with no partial state.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                                "trackIndex": ["type": "integer", "description": "Optional. Track index (0-based). Omit on every entry to auto-create one shared track per asset zone (video/audio)."],
                                "startFrame": ["type": "integer", "description": "Frame position to place the clip"],
                                "durationFrames": ["type": "integer", "description": "Duration in frames"],
                            ],
                            "required": ["mediaRef", "startFrame", "durationFrames"],
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
            name: .moveClips,
            description: "Moves one or more clips to a new track and/or frame position. Single undoable action. Each move specifies the clip ID and at least one of toTrack (must be compatible with the clip's media type) and toFrame. Overlap on the destination is resolved as in add_clips (existing clips on the destination track are trimmed/split/removed). Linked partners follow the named clip: startFrame propagates as a delta to preserve l-cut / j-cut offsets; tracks stay with the named clip.",
            inputSchema: objectSchema(
                properties: [
                    "moves": [
                        "type": "array",
                        "description": "Per-clip move requests. At least one of toTrack or toFrame is required per entry.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "clipId": ["type": "string", "description": "The clip ID to move."],
                                "toTrack": ["type": "integer", "description": "Destination track index (0-based). Omit to keep the clip on its current track."],
                                "toFrame": ["type": "integer", "description": "Destination start frame. Omit to keep the clip at its current start."],
                            ],
                            "required": ["clipId"],
                        ],
                    ],
                ],
                required: ["moves"]
            )
        ),
        AgentTool(
            name: .setClipProperties,
            description: "Apply the same property values to one or more clips in a single undoable action. Pass any combination of durationFrames, trimStartFrame, trimEndFrame, speed, volume, opacity, transform, or — for text clips only — content, fontName, fontSize, color, alignment. All values are applied to every clip in clipIds; for per-clip differences, make separate calls. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. transform uses 0–1 normalized canvas coords, partial merge (pass only centerY to reposition vertically); flipHorizontal/flipVertical mirror the clip across the corresponding axis (no effect on text clips). When a text clip's content or font changes without an explicit transform, the bounding box auto-refits. Text-only fields with any non-text clip in clipIds are rejected.\n\nFor moves and start-frame changes, use move_clips. For animated values (keyframes), use set_keyframes — setting volume or opacity here clears any existing keyframe track on that property.\n\nTiming changes (durationFrames, trimStartFrame, trimEndFrame, speed) on a linked clip carry over to its linked partner so audio/video stay in sync — same as the timeline UI. Per-clip fields (volume, opacity, transform, text*) don't propagate. trim and speed are skipped for text partners.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to update. The property values below apply to every clip in this list.",
                        "items": ["type": "string"],
                    ],
                    "durationFrames": ["type": "integer", "description": "New duration in frames."],
                    "trimStartFrame": ["type": "integer", "description": "Frames to trim from the start of the source media."],
                    "trimEndFrame": ["type": "integer", "description": "Frames to trim from the end of the source media."],
                    "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0)."],
                    "volume": ["type": "number", "description": "Volume 0.0-1.0. Clears any existing volume keyframes."],
                    "opacity": ["type": "number", "description": "Opacity 0.0-1.0. Clears any existing opacity keyframes."],
                    "transform": [
                        "type": "object",
                        "description": "Partial transform. Any combination of centerX, centerY, width, height, flipHorizontal, flipVertical; omitted fields keep their current value.",
                        "properties": [
                            "centerX": ["type": "number"],
                            "centerY": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                            "flipHorizontal": ["type": "boolean", "description": "Mirror across the vertical axis."],
                            "flipVertical": ["type": "boolean", "description": "Mirror across the horizontal axis."],
                        ],
                    ],
                    "content": ["type": "string", "description": "Text clips only. New text content."],
                    "fontName": ["type": "string", "description": "Text clips only. Font PostScript or family name."],
                    "fontSize": ["type": "number", "description": "Text clips only. Font size in canvas points."],
                    "color": ["type": "string", "description": "Text clips only. Hex '#RRGGBB' or '#RRGGBBAA'."],
                    "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text clips only."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .setKeyframes,
            description: "Set animated keyframes on one property of one clip. Replaces the existing keyframe track for that property (pass an empty array to clear). Frames are CLIP-RELATIVE offsets (0 = first frame of the clip), so keyframes follow the clip when it moves. Rows are sorted by frame internally and the LAST row for any duplicate frame wins. Values must be finite numbers. Each row is `[frame, ...values, interp?]` where interp ∈ {linear, hold, smooth} (default smooth).\n\nProperties and their value layouts:\n  • volume `[frame, value]` — value 0.0–1.0\n  • opacity `[frame, value]` — value 0.0–1.0\n  • rotation `[frame, degrees]` — clockwise degrees\n  • position `[frame, topLeftX, topLeftY]` — TOP-LEFT corner in 0–1 normalized canvas coords. NOT the center. (Default static transform centers a full-canvas clip, so top-left of the static is (0, 0); a centered half-size clip has top-left (0.25, 0.25).)\n  • scale `[frame, width, height]` — clip's normalized width and height in 0–1 canvas coords (1.0 = fills the canvas axis). NOT a scale factor.\n  • crop `[frame, top, right, bottom, left]` — side insets in 0–1 of the source media.\n\nMotion keyframes (position/scale/rotation) override the static `transform` value when active.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID."],
                    "property": [
                        "type": "string",
                        "enum": ["volume", "opacity", "rotation", "position", "scale", "crop"],
                        "description": "Which property's keyframe track to set.",
                    ],
                    "keyframes": [
                        "type": "array",
                        "description": "Replacement keyframe rows. Empty array clears the track. Row shape depends on property — see tool description.",
                        "items": ["type": "array"],
                    ],
                ],
                required: ["clipId", "property", "keyframes"]
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
            description: "Adds one or more text clips (titles, captions, lower-thirds) in a single undoable action. Text renders as an overlay on top of visual media. Transform uses 0–1 normalized canvas coords: (0.5,0.5) is center, (0.5,0.1) top-center, (0.5,0.9) bottom-center. Omit transform to center + auto-fit. Pass only centerX/centerY to reposition with auto-fit size (common for lower-thirds). Pass all four fields to override the box entirely. Colors are hex '#RRGGBB' or '#RRGGBBAA'.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates one new video track at the top and places all text clips there — the common case for captions. To target existing tracks, set trackIndex on every entry (audio tracks rejected). Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing (or earlier-batch) clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior. To show multiple text clips at the same time (stacked titles, simultaneous labels), put each on a DIFFERENT trackIndex so they layer instead of trimming each other.\n\nFor captioning spoken audio, prefer add_captions — it transcribes and places styled caption clips in one call. Use add_texts only for bespoke text (titles, lower-thirds) or captioning a custom range by hand. Unknown fields are rejected.",
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
            name: .addCaptions,
            description: "Auto-caption spoken audio: transcribes on-device and places styled caption clips on a new track — the same pipeline as the editor's Captions tab. This is the reliable path for 'caption this'; prefer it over hand-placing add_texts from a transcript. Omit clipIds to auto-pick the track with the most speech; pass clipIds to caption specific clips (e.g. only the interview).",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Optional. Audio/video clips to caption. Omit to auto-detect the primary spoken track."],
                    "fontSize": ["type": "number", "description": "Optional font size in canvas points (default 48)."],
                    "color": ["type": "string", "description": "Optional hex '#RRGGBB' or '#RRGGBBAA' (default white)."],
                    "centerX": ["type": "number", "description": "Optional horizontal center 0–1 (default 0.5)."],
                    "centerY": ["type": "number", "description": "Optional vertical center 0–1 (default 0.9, near the bottom)."],
                    "textCase": ["type": "string", "enum": ["auto", "upper", "lower"], "description": "Optional letter case (default auto)."],
                    "censorProfanity": ["type": "boolean", "description": "Optional. Mask profanity (default false)."],
                ]
            )
        ),
        AgentTool(
            name: .generateVideo,
            description: "Starts an async AI video generation. Returns a placeholder asset ID immediately; generation runs in the background and the asset becomes usable in add_clips once ready. Costs real money and is not undoable.",
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
                    "sourceClipId": ["type": "string", "description": "Optional. Clip id (from get_timeline) referencing sourceVideoMediaRef. When set and the clip is trimmed, only the clip's visible range is sent to the model, not the full source — matches the UI's 'Use trimmed portion only'."],
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of image references. Covers both reference-to-video generation (Seedance, Kling V3/O3 elements, Grok — refer as @Image1/@Element1 in prompt) and the single-image ref used by video-to-video edit models (Kling V3 Motion Control). See list_models maxReferenceImages for per-model cap."],
                    "referenceVideoMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of video references (Seedance only). Refer to them as @Video1, @Video2. See maxReferenceVideos and maxCombinedVideoRefSeconds."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of audio references (Seedance only). Refer to them as @Audio1, @Audio2. See maxReferenceAudios and maxCombinedAudioRefSeconds."],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
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
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .generateAudio,
            description: "Starts an async AI audio generation (text-to-speech or music). Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS models (elevenlabs-tts-v3, gemini-3.1-flash-tts) convert the prompt into speech and accept a 'voice' name. Music models (minimax-music-v2.6, elevenlabs-music) generate background tracks; pass 'lyrics' for MiniMax vocals or set 'instrumental' true for either music model. Only elevenlabs-music accepts 'duration'. Use list_models with type='audio' to see voices/capabilities. Costs real money and is not undoable.",
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
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
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
                    "sourceClipId": ["type": "string", "description": "Optional. Video clip id (from get_timeline) referencing mediaRef. When set and the clip is trimmed, only the clip's visible range is upscaled, not the full source."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .importMedia,
            description: "Imports external media into the project's library — the bridge for assets coming from other MCP servers (stock libraries, music services, web search) or local files the user already has. The 'source' object must set exactly one of: url (HTTPS only — downloaded in the background, the dominant case; max 1 GB), path (absolute local file path — referenced in place), or bytes (base64-encoded inline data — max ~15 MB of base64 ≈ 11 MB binary; use url/path for anything larger). For url, type is inferred from the URL path's file extension unless source.mimeType is set as an override (needed for signed URLs whose path has no usable extension). For bytes, source.mimeType is required.\n\nSupported types and extensions: video (mov, mp4, m4v), audio (mp3, wav, aac, m4a), image (png, jpg, jpeg, tiff, heic). Anything else is rejected — the caller must transcode externally.\n\nReturns a placeholder asset id immediately; URL imports run in the background and the asset becomes usable in add_clips once ready (same async pattern as generate_*). Path and bytes imports finalize synchronously. Costs nothing.",
            inputSchema: objectSchema(
                properties: [
                    "source": [
                        "type": "object",
                        "description": "Exactly one of url, path, or bytes must be set. mimeType is required when bytes is set; for url it acts as a type-inference override.",
                        "properties": [
                            "url": ["type": "string", "description": "HTTPS URL. Pre-signed URLs are fine but must not expire mid-download."],
                            "path": ["type": "string", "description": "Absolute local file path. The file must be readable by the Palmier process."],
                            "bytes": ["type": "string", "description": "Base64-encoded media data. Prefer url or path for anything over ~10MB."],
                            "mimeType": ["type": "string", "description": "Required when bytes is set. Optional override for url when its path has no usable extension (e.g. signed URLs). Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, image/png, image/jpeg, image/tiff, image/heic."],
                        ],
                    ],
                    "name": ["type": "string", "description": "Display name in the library. Defaults to the filename derived from url/path, or 'Imported asset' for bytes."],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: ["source"]
            )
        ),
        AgentTool(
            name: .listFolders,
            description: "Lists every folder in the media panel as {id, name, parentFolderId}. Folders are nested (parentFolderId is nil for top-level). Use to find an existing folder by name before generating new media.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .createFolder,
            description: "Creates a folder in the media panel and returns its id. Use to organize related generations (e.g. 'Hero shot variations'). Don't create folders for unrelated concepts.",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Folder name."],
                    "parentFolderId": ["type": "string", "description": "Optional parent folder id; omit for top level."],
                ],
                required: ["name"]
            )
        ),
        AgentTool(
            name: .moveToFolder,
            description: "Moves one or more existing media assets into a folder (or to the root if folderId is omitted). Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "assetIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Media asset ids to move.",
                    ],
                    "folderId": ["type": "string", "description": "Destination folder id. Omit to move to the project root."],
                ],
                required: ["assetIds"]
            )
        ),
        AgentTool(
            name: .renameMedia,
            description: "Renames a media asset in the library. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                    "name": ["type": "string", "description": "New display name."],
                ],
                required: ["mediaRef", "name"]
            )
        ),
        AgentTool(
            name: .renameFolder,
            description: "Renames a folder in the media panel. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "folderId": ["type": "string", "description": "Folder id from list_folders."],
                    "name": ["type": "string", "description": "New folder name."],
                ],
                required: ["folderId", "name"]
            )
        ),
        AgentTool(
            name: .deleteMedia,
            description: "Deletes media assets from the library. Any clips referencing them are removed from the timeline in the same undoable action.",
            inputSchema: objectSchema(
                properties: [
                    "assetIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Media asset ids to delete.",
                    ],
                ],
                required: ["assetIds"]
            )
        ),
        AgentTool(
            name: .deleteFolder,
            description: "Deletes folders and everything inside them (subfolders and assets). Clips referencing any deleted asset are removed from the timeline in the same undoable action.",
            inputSchema: objectSchema(
                properties: [
                    "folderIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Folder ids to delete.",
                    ],
                ],
                required: ["folderIds"]
            )
        ),
        AgentTool(
            name: .listModels,
            description: "Lists AI models with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support, voices/category for audio, upscaler speed). Always call before generate_video, generate_image, generate_audio, or upscale_media so the model you pick actually supports the constraints you need. Returns { models, loaded } — if loaded=false the catalog hasn't synced yet (e.g. user not signed in); the models array may be empty even when models exist, so do not conclude no models are available. Retry after the user signs in.",
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
