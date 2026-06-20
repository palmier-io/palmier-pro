import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
    case getTimeline = "get_timeline"
    case getMedia = "get_media"
    case addClips = "add_clips"
    case removeClips = "remove_clips"
    case removeTracks = "remove_tracks"
    case moveClips = "move_clips"
    case setClipProperties = "set_clip_properties"
    case setKeyframes = "set_keyframes"
    case splitClip = "split_clip"
    case rippleDeleteRanges = "ripple_delete_ranges"
    case undo = "undo"
    case addTexts = "add_texts"
    case addCaptions = "add_captions"
    case generateVideo = "generate_video"
    case generateImage = "generate_image"
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"
    case importMedia = "import_media"
    case listModels = "list_models"
    case inspectMedia = "inspect_media"
    case getTranscript = "get_transcript"
    case inspectTimeline = "inspect_timeline"
    case searchMedia = "search_media"
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
            description: "Always call at the start of a session. Returns project settings (fps, resolution, totalFrames), track list with types and order, all clips with their frames and properties, and canGenerate (if false, generation/upscale tools will fail — tell the user to sign in to Palmier and subscribe before attempting them). The clipId/trackId values here are what every other tool accepts.\n\nClip and track fields equal to their defaults are omitted: mediaType 'video', sourceClipType = mediaType, speed 1, volume 1, opacity 1, trims/fades 0, identity transform/crop, default textStyle, track muted/hidden false. Text clips never report trims (no source media).\n\nCaption clips (sharing a captionGroupId) come back per track as captionGroups instead of clips entries: properties common to the group are hoisted into 'shared' and each clip is a [clipId, startFrame, durationFrames, text] row (caption box width/height are auto-fit per text and omitted). Rows are capped at 200 per group — when clipCount exceeds the rows shown, page with startFrame/endFrame. Caption clips whose properties deviate from the group appear individually in clips.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Window start (inclusive); only clips intersecting [startFrame, endFrame) are returned. Tracks report totalClips when the window hides some."],
                    "endFrame": ["type": "integer", "description": "Optional. Window end (exclusive)."],
                ]
            )
        ),
        AgentTool(
            name: .getMedia,
            description: "Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus (generating | downloading | failed | none) for async-generated and -imported assets.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .inspectMedia,
            description: "Look at a media asset before referencing or editing it. Images: the image plus dimensions and EXIF. Video: sample frames plus a transcription of the audio track. Audio: transcription. Lottie: frames sampled evenly across the animation (over gray), plus framerate and duration — use this to verify a Lottie you wrote looks and moves right. Transcription is sentence-level segments — [text, start, end] tuples, capped at 400 — in source seconds, or project frames when clipId is set. When capped, pass the returned nextStartSeconds as startSeconds for the next page.\n\nLong media: pass overview=true for a one-image storyboard, read the segments, then re-call with startSeconds/endSeconds to zoom — windowed calls only transcribe that span, so they are fast.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Asset ID from get_media."],
                    "clipId": ["type": "string", "description": "Optional. A clip referencing this mediaRef; transcript times come back as project frames for that clip (out-of-range entries dropped)."],
                    "maxFrames": ["type": "integer", "description": "Video and Lottie. Sample frame count (default 6, max 12)."],
                    "startSeconds": ["type": "number", "description": "Video/audio. Source-time window start; scopes frames and transcription."],
                    "endSeconds": ["type": "number", "description": "Video/audio. Window end (default: asset duration)."],
                    "wordTimestamps": ["type": "boolean", "description": "Video/audio. Add word-level [text, start, end] tuples (capped at 10000 — most clips return all words at once; narrow with startSeconds/endSeconds only for very long media). Use for word-boundary edits like filler-word removal."],
                    "overview": ["type": "boolean", "description": "Video only. One storyboard grid of visually distinct, timestamped moments instead of frames — far more coverage per token; few tiles means static footage. maxFrames ignored."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .getTranscript,
            description: "Returns the spoken transcript of the CURRENT timeline in project frames — the post-edit caption track in one call. Unlike inspect_media (which transcribes one source asset in isolation, in source seconds), this walks every audio/video clip on the timeline, maps each word through that clip's trim/speed/position, and concatenates in timeline order. Deleted ranges are gone by construction, so after cuts this always reflects what's actually audible — no stale results, no per-clip frame math.\n\nReturns clips in timeline order, each with its words nested as compact [text, startFrame, endFrame] rows (the field order is given once in wordFormat) — clipId and trackIndex are stated once per clip, not repeated per word. Words are monotonic and non-overlapping; each is attributed to one clip, so a word split across a clip seam is emitted once, not re-emitted per clip. Pass a clip's clipId and a word's frames straight to ripple_delete_ranges. Capped at 10000 words total; page with startFrame/endFrame using nextStartFrame. Pass clipId to scope to a single clip (\"what does this clip say?\"). Transcription runs on-device.\n\nUse for transcript-driven edits (filler-word / dead-air removal, locating a quote, take selection) and to verify what remains after cutting.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Only return words ending after this project frame. Use with the returned nextStartFrame to page a long timeline."],
                    "endFrame": ["type": "integer", "description": "Optional. Only return words starting before this project frame."],
                    "clipId": ["type": "string", "description": "Scope the transcript to a single clip — returns only what that clip says, in project frames. Answers \"what's in clip X?\" without scanning the whole timeline."],
                ]
            )
        ),
        AgentTool(
            name: .inspectTimeline,
            description: "See the composited timeline — what the user actually sees in the preview at a given frame: all video tracks stacked with their transforms, opacity, crop, and keyframes applied, plus text and caption overlays baked in. Use this to verify your edits landed (a PIP's position, a title's placement, layer order) — inspect_media shows the raw source asset, not the cut.\n\nFrames are project frames (from get_timeline). Pass a single startFrame for one composited frame; add endFrame to sample maxFrames evenly across [startFrame, endFrame) for a transition or sequence. Frames past content render black. Returns frames downscaled for token efficiency, with the frameNumbers sampled.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Project frame to render (default 0). With no endFrame, a single frame is returned."],
                    "endFrame": ["type": "integer", "description": "Optional. Sample maxFrames evenly across [startFrame, endFrame) instead of one frame."],
                    "maxFrames": ["type": "integer", "description": "Frames to sample when endFrame is set (default 6, max 12)."],
                ]
            )
        ),
        AgentTool(
            name: .searchMedia,
            description: "Search the media library by content: what's on screen (visual) and what's said (spoken). Visual matching is semantic and on-device — phrase the query like an image caption ('a wide shot of a harbor at sunset'), not keywords; covers videos and stills. Spoken matching layers exact keywords over on-device semantic matching of transcript segments — quote the words said, or paraphrase them; transcripts are created automatically while indexing (and by inspect_media and add_captions), so coverage grows as indexing completes. The two groups rank independently and are never blended. Scores are uncalibrated — use them for ordering only.\n\nHits are source-second ranges. To place exactly that moment, multiply by fps and pass as trimStartFrame/trimEndFrame with a matching durationFrames to add_clips or set_clip_properties. Image hits have no time range.\n\nstatus reports the visual index: ready | indexing | modelNotInstalled | downloadingModel | preparing | disabled | failed. When not ready, moments may be empty or incomplete (compare indexedAssets to indexableAssets) — report that instead of concluding the footage doesn't exist, and don't poll in a loop. Spoken results work regardless of status.",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "What to find. Visual: a caption-style scene description. Spoken: the words to match."],
                    "scope": ["type": "string", "enum": ["visual", "spoken", "both"], "description": "Optional. Default both."],
                    "mediaRef": ["type": "string", "description": "Optional. Restrict the search to one asset from get_media."],
                    "limit": ["type": "integer", "description": "Optional. Max hits per group (default 10, max 50)."],
                ],
                required: ["query"]
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
            name: .removeTracks,
            description: "Removes whole tracks and every clip on them in one undoable action. Linked partners on OTHER tracks are not removed. Remaining track indexes shift down after removal.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndexes": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Track indexes (0-based, from get_timeline) to remove.",
                    ],
                ],
                required: ["trackIndexes"]
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
                    "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0). >1 speeds up, <1 slows down. The clip's timeline length is rescaled to keep the same source content (2x speed → half the frames), unless you also pass durationFrames to set the length explicitly."],
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
            name: .rippleDeleteRanges,
            description: "Cuts one or more ranges out and closes the gaps in one undoable action — the fast path for filler-word/dead-air removal. Replaces hand-cranked split_clip → split_clip → remove_clips → move_clips loops: pass every range at once.\n\nTwo modes — pass exactly one of clipId or trackIndex:\n• trackIndex (preferred for transcript-driven cuts): ranges are PROJECT frames and may span any number of clips on that track. get_transcript returns a clips array with nested words in project frames — collect every cut across the whole timeline and pass them in ONE call, no per-clip splitting and no re-reading the timeline between cuts. units must be 'frames'.\n• clipId: ranges are cut within that single clip only, clamped to its visible span. Allows units 'seconds' (source-media seconds, e.g. inspect_media WITHOUT a clipId or search_media hits); 'frames' = project frames. Use when you already have one clip's per-word timestamps.\n\nOverlapping ranges merge. Linked audio/video partners of every touched clip are cut on the same span so A/V stays in sync. Remaining clips shift left to close every gap; sync-locked tracks shift along to preserve alignment (their content isn't cut). Refuses without changing anything if a sync-locked track can't absorb the shift (e.g. it would move past frame 0). Returns the anchor track's post-cut layout (clip ids/frames) so you don't need to re-read.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndex": ["type": "integer", "description": "Cut project-frame ranges spanning every clip they cross on this track, in one call. From get_transcript's clips array. Mutually exclusive with clipId; requires units 'frames'."],
                    "clipId": ["type": "string", "description": "Cut ranges within this single clip only, clamped to its visible span. Mutually exclusive with trackIndex."],
                    "ranges": [
                        "type": "array",
                        "description": "Ranges to remove, each a [start, end] pair (end > start). In the unit given by 'units'.",
                        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                    ],
                    "units": ["type": "string", "enum": ["seconds", "frames"], "description": "Interpretation of range values. 'frames' (default) = project/timeline frames, matching get_transcript and inspect_media-with-clipId. 'seconds' = source-media seconds (clipId mode only)."],
                ],
                required: ["ranges"]
            )
        ),
        AgentTool(
            name: .undo,
            description: "Reverts the assistant's most recent timeline edit (a cut, move, trim, split, or clip/text/caption add) as one step. The recovery path when an edit went too far — e.g. a ripple_delete_ranges removed more than intended. Verify a cut first (get_transcript reflects the post-cut audio), then undo if it overshot, then retry with corrected ranges.\n\nUndoes only edits the assistant made this session, most-recent-first — it never touches the user's own manual edits, and refuses if the latest change wasn't the assistant's. After undoing, the timeline is restored to its state before that edit; the ids/frames the edit returned are no longer valid, so re-read with get_timeline or get_transcript if you'll edit again. Takes no arguments.",
            inputSchema: objectSchema()
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
                    "language": ["type": "string", "description": "Optional BCP-47 language of the speech (e.g. 'es', 'ja', 'en-GB'). Defaults to the system language — set this when the footage is in another language, or transcription will be garbage."],
                    "fontName": ["type": "string", "description": "Optional font PostScript or family name (default 'Helvetica-Bold'). Falls back to bold system font if not found."],
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
            description: "Starts an async AI audio generation: text-to-speech, text-to-music, or video-to-music (scoring a video). Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS models (elevenlabs-tts-v3, gemini-3.1-flash-tts) convert the prompt into speech and accept a 'voice'. Music models (lyria3-pro, minimax-music-v2.6, elevenlabs-music, sonilo-v1.1-video-to-music) generate tracks from a prompt; include lyrics/tempo/vocal style in the prompt for Lyria 3 Pro, pass 'lyrics' for MiniMax vocals, or set 'instrumental' true when the selected model supports it. Video-to-audio models (inputs include 'video' — see list_models, e.g. sonilo-v1.1-video-to-music, mirelo-sfx-v1.5-video-to-audio) generate audio that matches a VIDEO: provide a timeline span via videoSourceStartFrame+videoSourceEndFrame (e.g. to score the timeline), or a video asset via videoSourceMediaRef; the prompt is then an optional style guide. PLACEMENT: when you pass a timeline span, the result is placed on the timeline automatically at that span (no add_clips needed); for a media-asset source or a plain text-to-speech/music result, the asset lands in the library and you place it with add_clips. Use list_models with type='audio' to see each model's 'inputs', category, and voices. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Required for TTS (the text to speak) and text-to-music (style/mood/genre; MiniMax needs ≥10 chars). For Lyria 3 Pro, include lyrics, tempo, language, and vocal style directly in the prompt. Optional style guide for video-to-music models."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID. Use list_models with type='audio' to see options and their 'inputs'. Defaults to the first model."],
                    "voice": ["type": "string", "description": "TTS only. Voice preset name. list_models shows voicesSample (first 3) + voiceCount; any voice supported by the model is accepted. Defaults to the model's defaultVoice. Ignored by music models."],
                    "lyrics": ["type": "string", "description": "MiniMax Music only. Lyrics with optional [Verse]/[Chorus] section tags. If omitted and instrumental=false, MiniMax auto-writes lyrics from the prompt."],
                    "styleInstructions": ["type": "string", "description": "Gemini TTS only. Optional delivery instructions (e.g. 'warm and slow', 'British accent')."],
                    "instrumental": ["type": "boolean", "description": "Music models only. true = no vocals when the selected model supports it. Defaults to false."],
                    "duration": ["type": "integer", "description": "Length in seconds. ElevenLabs Music: 3–600. Sonilo text-to-music: up to 600. For a video source, defaults to the span/clip length. Ignored by TTS, MiniMax, and Lyria 3 Pro."],
                    "videoSourceStartFrame": ["type": "integer", "description": "Video-to-audio models only. Start frame (timeline) of a span to render and score — pair with videoSourceEndFrame. Use get_timeline for frame numbers; for the whole timeline use 0 to the timeline's end frame."],
                    "videoSourceEndFrame": ["type": "integer", "description": "Video-to-audio models only. End frame (exclusive) of the span to score. Must be > videoSourceStartFrame."],
                    "videoSourceMediaRef": ["type": "string", "description": "Video-to-audio models only. Score this existing video asset instead of a timeline span. Mutually exclusive with the videoSource frames."],
                    "folderId": ["type": "string", "description": "Optional. Folder id (from list_folders or create_folder) to place the result in. Omit for the project root."],
                ],
                required: []
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
            description: "Creates folders in the media panel. Pass either name/parentFolderId for one folder or entries for multiple folders, not both. Direct form returns one folder; entries returns { folders }. Undoable. Use to organize related generations (e.g. 'Hero shot variations'). Don't create folders for unrelated concepts.",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Folder name."],
                    "parentFolderId": ["type": "string", "description": "Optional parent folder id; omit for top level."],
                    "entries": [
                        "type": "array",
                        "description": "Folders to create in one undoable action.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Folder name."],
                                "parentFolderId": ["type": "string", "description": "Optional parent folder id; omit for top level."],
                            ],
                            "required": ["name"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .moveToFolder,
            description: "Moves media assets to folders. Pass either assetIds/folderId for one destination or entries for multiple destinations, not both. Omit folderId to move to root. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "assetIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Media asset ids to move.",
                    ],
                    "folderId": ["type": "string", "description": "Destination folder id. Omit to move to the project root."],
                    "entries": [
                        "type": "array",
                        "description": "Move operations to apply in one undoable action. Each entry can target a different folder.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "assetIds": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Media asset ids to move.",
                                ],
                                "folderId": ["type": "string", "description": "Destination folder id. Omit to move to the project root."],
                            ],
                            "required": ["assetIds"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .renameMedia,
            description: "Renames media assets in the library. Pass either mediaRef/name for one asset or entries for multiple assets, not both. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                    "name": ["type": "string", "description": "New display name."],
                    "entries": [
                        "type": "array",
                        "description": "Media assets to rename in one undoable action.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                                "name": ["type": "string", "description": "New display name."],
                            ],
                            "required": ["mediaRef", "name"],
                        ],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .renameFolder,
            description: "Renames folders in the media panel. Pass either folderId/name for one folder or entries for multiple folders, not both. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "folderId": ["type": "string", "description": "Folder id from list_folders."],
                    "name": ["type": "string", "description": "New folder name."],
                    "entries": [
                        "type": "array",
                        "description": "Folders to rename in one undoable action.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "folderId": ["type": "string", "description": "Folder id from list_folders."],
                                "name": ["type": "string", "description": "New folder name."],
                            ],
                            "required": ["folderId", "name"],
                        ],
                    ],
                ]
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
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = valueFromJSON(v) }
            return .object(out)
        default: return .null
        }
    }
}

enum ToolArgsBridge {
    static func argsFromMCP(_ args: [String: Value]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(args.count)
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
            out.reserveCapacity(obj.count)
            for (k, v) in obj { out[k] = anyFromValue(v) }
            return out
        }
    }
}
