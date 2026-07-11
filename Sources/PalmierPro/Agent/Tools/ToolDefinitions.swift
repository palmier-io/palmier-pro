import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
    // Projects
    case getProjects = "get_projects"
    case openProject = "open_project"
    case newProject = "new_project"
    case closeProject = "close_project"

    // Timelines
    case getTimeline = "get_timeline"
    case inspectTimeline = "inspect_timeline"
    case createTimeline = "create_timeline"
    case setActiveTimeline = "set_active_timeline"
    case setProjectSettings = "set_project_settings"
    case exportProject = "export_project"

    // Media library
    case getMedia = "get_media"
    case inspectMedia = "inspect_media"
    case searchMedia = "search_media"
    case importMedia = "import_media"
    case organizeMedia = "organize_media"

    // Clips
    case manageTracks = "manage_tracks"
    case addClips = "add_clips"
    case insertClips = "insert_clips"
    case moveClips = "move_clips"
    case removeClips = "remove_clips"
    case splitClips = "split_clips"
    case rippleDeleteRanges = "ripple_delete_ranges"
    case setClipProperties = "set_clip_properties"
    case setKeyframes = "set_keyframes"
    case applyLayout = "apply_layout"
    case syncClips = "sync_clips"
    case undo = "undo"

    // Multicam
    case manageMulticam = "manage_multicam"
    case changeCam = "change_cam"
    case getMulticam = "get_multicam"

    // Transcript
    case getTranscript = "get_transcript"
    case removeWords = "remove_words"
    case removeSilence = "remove_silence"
    case detectBeats = "detect_beats"

    // Text & captions
    case addTexts = "add_texts"
    case updateText = "update_text"
    case addCaptions = "add_captions"

    // Color & effects
    case applyColor = "apply_color"
    case applyEffect = "apply_effect"
    case inspectColor = "inspect_color"
    case denoiseAudio = "denoise_audio"

    // Generation
    case listModels = "list_models"
    case generateVideo = "generate_video"
    case generateImage = "generate_image"
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"

    // Meta
    case sendFeedback = "send_feedback"
    case readSkill = "read_skill"
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
            description: "Always call at the start of a session. Returns project settings (fps, resolution, totalFrames, durationSeconds), tracks with their index (what every trackIndex parameter takes), type, and clips, plus canGenerate (if false, generation/upscale tools will fail — tell the user to sign in to Palmier and subscribe before attempting them). The clipId values here are what every other tool accepts.\n\nEvery clip occupies frames: [start, end) — timeline frames, end exclusive, duration = end − start. gaps on a track lists its empty [start, end) spans; no gaps key means contiguous. A video clip's linked audio partner is folded into it as audio: {id, track, …} carrying only what deviates (volume, effects, differing trims); the partner is not repeated on its own track, which instead reports linkedClips (its folded count). Address the audio side by its nested id.\n\nFields equal to their defaults are omitted: mediaType 'video', sourceClipType = mediaType, speed 1, volume 1, opacity 1, trims/fades 0, identity transform/crop, default textStyle, track muted/hidden false. Text clips never report trims. Keyframe tracks that animate nothing are shown as what they are: identity tracks are dropped, constant ones appear as the static field (e.g. crop: {left: 0.31}). A graded clip carries `color` — its grade in apply_color's own vocabulary, pasteable to other clips via apply_color's color parameter. Other effects appear as effects: [{type, params}], the exact shape apply_effect accepts.\n\nCaption clips (sharing a captionGroupId) come back per track as captionGroups summaries: clipCount, frameRange, shared style, and a textPreview — individual caption clips and their ids are NOT listed. That summary is all you need to restyle (update_text with captionGroupId) or judge coverage; the spoken words live in get_transcript. Only when you must touch individual caption clips (retime one, delete one, fix one word's style), re-read with captionDetail:true — ideally windowed — to get [clipId, startFrame, endFrame, text] rows, capped at 200 per group. Caption clips whose properties deviate from the group always appear individually in clips.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Window start (inclusive); only clips intersecting [startFrame, endFrame) are returned. Tracks report totalClips when the window hides some."],
                    "endFrame": ["type": "integer", "description": "Optional. Window end (exclusive)."],
                    "captionDetail": ["type": "boolean", "description": "Optional. true expands captionGroups into per-clip [clipId, startFrame, endFrame, text] rows. Combine with a window; only needed to edit individual caption clips."],
                ]
            )
        ),
        AgentTool(
            name: .inspectTimeline,
            description: "See the composited timeline — what the user actually sees in the preview at a given frame: all video tracks stacked with their transforms, opacity, crop, and keyframes applied, plus text and caption overlays baked in. Use this to verify your edits landed (a PIP's position, a title's placement, layer order) — inspect_media shows the raw source asset, not the cut.\n\nFrames are project frames (from get_timeline). Pass a single startFrame for one composited frame; add endFrame to sample maxFrames evenly across [startFrame, endFrame) for a transition or sequence. Frames past content render black. Each image carries its frame number burned into the top-left (f157), and the metadata lists, per rendered frame, the clip ids visible on screen top-down (caption clips as their captionGroupId) — so what you see maps straight back to the clips to edit.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Project frame to render (default 0). With no endFrame, a single frame is returned."],
                    "endFrame": ["type": "integer", "description": "Optional. Sample maxFrames evenly across [startFrame, endFrame) instead of one frame."],
                    "maxFrames": ["type": "integer", "description": "Frames to sample when endFrame is set (default 6, max 12)."],
                ]
            )
        ),
        AgentTool(
            name: .createTimeline,
            description: "Creates a timeline and switches to it — every read and edit tool now targets it. Without 'from', the new timeline is empty and inherits fps/resolution from the previously active one. With 'from', it's a full copy of that timeline — the versioning primitive: copy, then edit the copy (\"a tighter cut\", \"a 9:16 version\") while the original stays intact; every clip and track id in the copy is NEW, so re-read get_timeline before editing. Undoable.\n\nUse timelines to organize a project: alternate versions, sections assembled separately, or reusable groups. A timeline can be placed inside another as a single clip (add_clips with the timelineId as mediaRef); it then appears as a clip with mediaType 'sequence'.",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Optional display name. Defaults to 'Timeline N', or '<source> copy' when duplicating."],
                    "from": ["type": "string", "description": "Optional timelineId to duplicate instead of creating empty."],
                ]
            )
        ),
        AgentTool(
            name: .setActiveTimeline,
            description: "Switches the active timeline — the one every read and edit tool targets and the one the user sees. get_media lists the project's timelines (with timelineId). Always re-read get_timeline after switching; clip and track ids from the previous timeline are no longer valid targets.\n\nTo edit the contents of a nested timeline (a clip with mediaType 'sequence'), switch to its mediaRef.",
            inputSchema: objectSchema(
                properties: [
                    "timelineId": ["type": "string", "description": "Timeline id from get_media's timelines list (or a sequence clip's mediaRef)."],
                ],
                required: ["timelineId"]
            )
        ),
        AgentTool(
            name: .setProjectSettings,
            description: "Change the project's frame rate, resolution, or aspect ratio. Pass any combination of fps, explicit width+height, aspectRatio, and quality. aspectRatio and explicit width/height are mutually exclusive; quality scales the current aspect ratio (or the selected preset when combined with aspectRatio). The timeline's existing clips are re-fitted automatically: auto-fit transforms recalculate for the new canvas size, and all frame positions/durations rescale when fps changes. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "fps": ["type": "integer", "description": "Frame rate in frames per second. Common values: 24, 25, 30, 48, 50, 60."],
                    "width": ["type": "integer", "description": "Canvas width in pixels. Use with height for an exact resolution. Mutually exclusive with aspectRatio."],
                    "height": ["type": "integer", "description": "Canvas height in pixels. Use with width for an exact resolution. Mutually exclusive with aspectRatio."],
                    "aspectRatio": ["type": "string", "enum": ["16:9", "9:16", "1:1", "4:3", "2.4:1", "9:14"], "description": "Preset aspect ratio — sets both width and height from the preset, or combined with quality to pick a specific size. Mutually exclusive with width/height."],
                    "quality": ["type": "string", "enum": ["720p", "1080p", "2K", "4K"], "description": "Resolution quality preset — scales the short edge to the target while preserving the current (or specified) aspect ratio."],
                ]
            )
        ),
        AgentTool(
            name: .exportProject,
            description: "Exports from the current project using the same modes as the Export dialog. mode defaults to video. video renders H.264, H.265, or ProRes; xml writes XMEML timeline XML; fcpxml writes FCPXML; palmier writes a self-contained .palmier project package. For timeline interchange, pick the format by the target editor: Premiere Pro -> xml; DaVinci Resolve or Final Cut Pro -> fcpxml (fcpxml also carries text, transforms, crop, opacity, and keyframes that xml cannot). Omit outputPath to write a unique file to ~/Downloads. Existing direct outputPath files are overwritten by default to match the UI save flow; pass overwrite=false to refuse. video renders in the background and returns status=started with the destination path; the app posts a system notification on completion or failure, so do not expect a final result inline. xml, fcpxml, and palmier finish before returning and report their result inline.",
            inputSchema: objectSchema(
                properties: [
                    "mode": ["type": "string", "enum": ["video", "xml", "fcpxml", "palmier"], "description": "Optional. Default video. Use xml for Premiere Pro, fcpxml for DaVinci Resolve or Final Cut Pro."],
                    "codec": ["type": "string", "enum": ["H.264", "H.265", "ProRes"], "description": "Video mode only. Optional. Default H.264."],
                    "resolution": ["type": "string", "enum": ["720p", "1080p", "2K", "4K", "Match Timeline"], "description": "Video mode only. Optional. Default Match Timeline."],
                    "outputPath": ["type": "string", "description": "Optional. Absolute destination path. If omitted, a unique project-named file is written to ~/Downloads. If no extension is provided, the mode's extension is appended."],
                    "overwrite": ["type": "boolean", "description": "Optional. Default true, matching the UI save flow. false refuses when outputPath already exists."],
                    "fcpxmlTarget": ["type": "string", "enum": ["resolve", "fcp"], "description": "fcpxml mode only. Optional, default resolve. Davinci Resolve and Final Cut interpret crop and position values differently; pick the app the file will be imported into."],
                    "timelineId": ["type": "string", "description": "Optional. Timeline to export (from get_timeline's timelines list). Defaults to the active timeline. Not valid for palmier mode, which packages every timeline."],
                ]
            )
        ),
        AgentTool(
            name: .getMedia,
            description: "The library inventory: media assets, folders, and timelines. Call before referencing any asset — every mediaRef in other tools comes from the asset ids returned here. Assets report name, type, durationSeconds, width/height/fps, hasAudio, folder path, and (for AI-generated assets) the generation prompt as a content hint. generationStatus appears only while an async generation/import is unresolved (preparing | generating | downloading | failed) — its absence means the asset is ready.\n\nFilters: ids (poll specific placeholders cheaply), folder (a path; includes subfolders), pending:true (only unresolved generations/imports). Filtered reads return just the matching assets; unfiltered reads also include folders (as paths) and timelines.",
            inputSchema: objectSchema(
                properties: [
                    "ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optional. Return only these asset ids — the cheap way to poll a generation placeholder.",
                    ],
                    "folder": ["type": "string", "description": "Optional folder path filter, e.g. 'B-roll/Sunset'. Includes subfolders."],
                    "pending": ["type": "boolean", "description": "Optional. true returns only assets with an unresolved generationStatus."],
                ]
            )
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
                    "language": ["type": "string", "description": "Optional BCP-47 language tag of the spoken audio (e.g. 'es', 'fr', 'ja', 'zh-Hans'). Defaults to the system language. Specify when the spoken language differs from the system locale — on-device models are language-specific and will produce garbled output if the wrong language is used."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .searchMedia,
            description: "Search the media library by content: what's on screen (visual) and what's said (spoken). Visual matching is semantic and on-device — phrase the query like an image caption ('a wide shot of a harbor at sunset'), not keywords; covers videos and stills. Spoken matching layers exact keywords over on-device semantic matching of transcript segments — quote the words said, or paraphrase them; transcripts are created automatically while indexing (and by inspect_media and add_captions), so coverage grows as indexing completes. The two groups rank independently and are never blended. Scores are uncalibrated — use them for ordering only.\n\nHits are source-second ranges (image hits have no time range). To place exactly that moment, pass [startSeconds, endSeconds] straight to add_clips as source — no unit conversion.\n\nAn `index` object appears only while it can explain missing results (status: indexing | modelNotInstalled | downloadingModel | preparing | disabled | failed, with indexedAssets vs indexableAssets). When present, moments may be incomplete — report that instead of concluding the footage doesn't exist, and don't poll in a loop. No index key means visual search was complete. Spoken results work regardless.",
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
            name: .importMedia,
            description: "Imports external media into the project's library — the bridge for assets coming from other MCP servers (stock libraries, music services, web search) or local files the user already has. The 'source' object must set exactly one of: url (HTTPS only — downloaded in the background, the dominant case; max 1 GB), path (absolute local file path — copied into the project in the background; may also be a directory, which is imported recursively, mirroring its subfolder structure as media folders), bytes (base64-encoded inline data — max ~15 MB of base64 ≈ 11 MB binary; use url/path for anything larger), or matte (a generated solid-color PNG). For url, type is inferred from the URL path's file extension unless source.mimeType is set as an override (needed for signed URLs whose path has no usable extension). For bytes, source.mimeType is required.\n\nSupported types and extensions: video (mov, mp4, m4v), audio (mp3, wav, aac, m4a, aiff, aifc, flac), image (png, jpg, jpeg, tiff, heic). Anything else is rejected — the caller must transcode externally.\n\nurl and file-path imports run in the background and return {mediaRef, status:'downloading'} — poll get_media with ids:[mediaRef] until generationStatus clears, then the asset is usable in add_clips. Directory, bytes, and matte imports finish inline with status:'ready'. Costs nothing.",
            inputSchema: objectSchema(
                properties: [
                    "source": [
                        "type": "object",
                        "description": "Exactly one of url, path, bytes, or matte must be set. mimeType is required when bytes is set; for url it acts as a type-inference override.",
                        "properties": [
                            "url": ["type": "string", "description": "HTTPS URL. Pre-signed URLs are fine but must not expire mid-download."],
                            "path": ["type": "string", "description": "Absolute local file or directory path, readable by the Palmier process. A directory is imported recursively — every openable file is pulled in and the folder structure is replicated as media folders."],
                            "bytes": ["type": "string", "description": "Base64-encoded media data. Prefer url or path for anything over ~10MB."],
                            "matte": [
                                "type": "object",
                                "description": "Generates a solid-color PNG matte instead of importing a file.",
                                "properties": [
                                    "hex": ["type": "string", "description": "Hex color, e.g. '#000000' or '#FFFFFF'."],
                                    "aspectRatio": [
                                        "type": "string",
                                        "enum": ["Project", "16:9", "9:16", "1:1", "4:3", "9:14", "2.4:1"],
                                        "description": "Defaults to Project (timeline resolution). Other values use the project's short edge.",
                                    ],
                                ],
                                "required": ["hex"],
                            ],
                            "mimeType": ["type": "string", "description": "Required when bytes is set. Optional override for url when its path has no usable extension (e.g. signed URLs). Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, image/png, image/jpeg, image/tiff, image/heic."],
                        ],
                    ],
                    "name": ["type": "string", "description": "Display name in the library. Defaults to the filename derived from url/path, or 'Imported asset' for bytes."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'B-roll/Sunset'. Created if missing. Omit for the project root."],
                ],
                required: ["source"]
            )
        ),
        AgentTool(
            name: .organizeMedia,
            description: "Reorganizes the library in one undoable action: create folders, move items into folders, rename items, delete items. An item is a media asset id (from get_media), a timelineId, or a folder path like 'B-roll/Sunset' — the tool tells them apart. Folders are always addressed by path, never by id; destination paths are created if missing. Arrays apply in order (createFolders, moves, renames, deletes), but item references resolve against the library as it was before the call — only 'into' destinations may name folders the same call creates.\n\nDeleting an asset also removes every clip referencing it (reported as clipsRemoved). Deleting a folder deletes its subfolders and assets; timelines inside move to the root instead. Deleting a timeline leaves nest clips referencing it rendering black (a warning reports how many); the last remaining timeline can't be deleted. Returns only what actually happened — createdFolders, moved, renamed, deleted, clipsRemoved, warnings.",
            inputSchema: objectSchema(
                properties: [
                    "createFolders": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Folder paths to ensure exist, e.g. ['Hero shots/Takes']. Existing folders are left alone. Rarely needed — moves and generation 'folder' params create folders on their own.",
                    ],
                    "moves": [
                        "type": "array",
                        "description": "Each entry files items into one destination folder.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "items": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Asset ids, timeline ids, and/or folder paths to move.",
                                ],
                                "into": ["type": "string", "description": "Destination folder path; created if missing. Omit to move to the project root."],
                            ],
                            "required": ["items"],
                        ],
                    ],
                    "renames": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "item": ["type": "string", "description": "Asset id, timeline id, or folder path."],
                                "name": ["type": "string", "description": "New display name (a name, not a path — renaming never moves)."],
                            ],
                            "required": ["item", "name"],
                        ],
                    ],
                    "deletes": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Asset ids, timeline ids, and/or folder paths to delete.",
                    ],
                ]
            )
        ),
        AgentTool(
            name: .addClips,
            description: "Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). The whole batch is one undo step.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates the needed tracks — one shared video track for visual entries and one shared audio track for audio entries (matches the captioning pattern in add_texts). To target existing tracks, set trackIndex on every entry. Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior.\n\nNESTING: mediaRef may also be a timelineId — the timeline is placed as a single live nested clip (mediaType 'sequence'), with a linked audio clip when the child has audio. Duration defaults to the child's full length; source and endFrame work as for video. Cycles (a timeline containing itself) and empty timelines are rejected.",
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
                                "startFrame": ["type": "integer", "description": "Timeline frame position to place the clip (project frames)."],
                                "endFrame": ["type": "integer", "description": "Optional. Occupy timeline frames [startFrame, endFrame) — a gap from get_timeline copies straight in. For stills and frame-exact fills. Mutually exclusive with source."],
                                "source": ["type": "array", "items": ["type": "number"], "description": "Optional. [startSeconds, endSeconds] — which span of the source to use, in the source seconds search_media hits and inspect_media segments speak. For stills this is the display length in seconds. Omit both for the whole asset. Mutually exclusive with endFrame."],
                            ],
                            "required": ["mediaRef", "startFrame"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .insertClips,
            description: "Inserts one or more media assets at a single point and RIPPLES: every clip at or after atFrame is pushed right to open a gap, so nothing is overwritten. This is the non-destructive counterpart to add_clips (which clears the landing region, trimming/splitting/removing whatever's there). Use insert_clips to splice footage in without losing existing clips; use add_clips to fill empty space or deliberately overwrite.\n\nEntries are laid end-to-end starting at atFrame on the target track (entry[0] at atFrame, entry[1] immediately after, ...). The push equals the sum of the entries' durations and is applied to the target track, every sync-locked track, AND the audio track any auto-created linked audio lands on — so a clip and its linked audio stay aligned. As in add_clips, a video asset with audio spawns a linked audio clip. One undoable action; one bad entry rejects the whole call with no partial state.\n\ntrackIndex is required — ripple needs an existing track to push. For placement into empty space, use add_clips.\n\nAs in add_clips, mediaRef may be a timelineId to splice in a nested timeline.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndex": ["type": "integer", "description": "Track index (0-based, from get_timeline) to insert into and ripple."],
                    "atFrame": ["type": "integer", "description": "Timeline frame (project frames) where insertion begins. Every clip at or after this frame on rippled tracks shifts right by the total inserted duration."],
                    "entries": [
                        "type": "array",
                        "description": "Clips to insert, placed sequentially from atFrame. Validated up front; one bad entry rejects the whole call.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media."],
                                "source": ["type": "array", "items": ["type": "number"], "description": "Optional. [startSeconds, endSeconds] — which span of the source to use, in source seconds; for stills, the display length. Omit for the whole asset. Mutually exclusive with durationFrames."],
                                "durationFrames": ["type": "integer", "description": "Optional. Exact length in project frames (entries stack end-to-end, so they have lengths, not positions). Mutually exclusive with source."],
                            ],
                            "required": ["mediaRef"],
                        ],
                    ],
                ],
                required: ["trackIndex", "atFrame", "entries"]
            )
        ),
        AgentTool(
            name: .moveClips,
            description: "Moves one or more clips to a new track and/or frame position. Single undoable action. Each move specifies the clip ID and at least one of toTrack (must be compatible with the clip's media type) and toFrame. Overlap on the destination is resolved as in add_clips (existing clips on the destination track are trimmed/split/removed). Linked partners follow the named clip: startFrame propagates as a delta to preserve l-cut / j-cut offsets; tracks stay with the named clip. Multicam clips must move as a whole group; partial group moves and camera lane changes are refused.",
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
            name: .manageTracks,
            description: "Track-level operations in one undoable action: reorder (stacking order — index 0 renders on top; a video track can only move within the video zone, audio within audio), set flags (muted silences an audio track; hidden excludes a video track from the render; syncLocked controls whether ripple edits shift it), and remove (deletes tracks with every clip on them; linked partners on OTHER tracks stay). Arrays run reorder → set → remove; every index refers to the track order at call time (resolved up front). Returns the resulting track order — remaining indexes shift after reorder/remove. Tracks holding multicam clips can't be removed or sync-unlocked (mute/hide stay free).",
            inputSchema: objectSchema(
                properties: [
                    "reorder": [
                        "type": "array",
                        "description": "Moves, applied in order. Use to fix stacking, e.g. bring a PIP inset's track to index 0.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer", "description": "Track to move (0-based, current order)."],
                                "to": ["type": "integer", "description": "Destination index; clamped to the track's type zone."],
                            ],
                            "required": ["index", "to"],
                        ],
                    ],
                    "set": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer", "description": "Track to change (0-based, current order)."],
                                "muted": ["type": "boolean", "description": "Silence/unsilence the track's audio."],
                                "hidden": ["type": "boolean", "description": "Exclude/include a video track in the render."],
                                "syncLocked": ["type": "boolean", "description": "Whether ripple edits shift this track along."],
                            ],
                            "required": ["index"],
                        ],
                    ],
                    "remove": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Track indexes to remove, with all their clips.",
                    ],
                ]
            )
        ),
        AgentTool(
            name: .splitClips,
            description: "Splits clips into two at one or more cut points, all in a single undoable action. A split only inserts a boundary — it never trims media or moves clips, so unlike ripple_delete_ranges nothing shifts and there's no gap to close.\n\nTwo modes — pass exactly one:\n• splits: an array of {clipId, atFrame} (project frames). Use when you know the clip IDs.\n• trackIndex + frames: cut one track at the given project frames; each frame is matched to whichever clip on that track contains it. Pairs naturally with get_transcript / get_timeline project frames.\n\nEvery frame must fall strictly between a clip's start and end. Multiple cuts on the SAME clip are allowed — pass all the frames at once and each is resolved against the current sub-clips. Duplicate cut points are ignored. Linked audio/video partners are split at the same frame so A/V stays in sync, and the right halves are regrouped into their own link pair. One bad cut point rejects the whole call with no partial state.",
            inputSchema: objectSchema(
                properties: [
                    "splits": [
                        "type": "array",
                        "description": "Explicit cuts. Each item is {clipId, atFrame}.",
                        "items": objectSchema(
                            properties: [
                                "clipId": ["type": "string", "description": "The clip ID to split"],
                                "atFrame": ["type": "integer", "description": "Project frame to split at (strictly between clip start and end)"],
                            ],
                            required: ["clipId", "atFrame"]
                        ),
                    ],
                    "trackIndex": ["type": "integer", "description": "Track to cut (use with 'frames')"],
                    "frames": [
                        "type": "array",
                        "description": "Project frames to cut on trackIndex; each is matched to the clip containing it.",
                        "items": ["type": "integer"],
                    ],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .rippleDeleteRanges,
            description: "Cuts one or more ranges out and closes the gaps in one undoable action — the fast path for filler-word/dead-air removal. Replaces hand-cranked split_clips → remove_clips → move_clips loops: pass every range at once.\n\nTwo modes — pass exactly one of clipId or trackIndex:\n• trackIndex (preferred for transcript-driven cuts): ranges are PROJECT frames and may span any number of clips on that track. get_transcript returns a clips array with nested words in project frames — collect every cut across the whole timeline and pass them in ONE call, no per-clip splitting and no re-reading the timeline between cuts. units must be 'frames'.\n• clipId: ranges are cut within that single clip only, clamped to its visible span. Allows units 'seconds' (source-media seconds, e.g. inspect_media WITHOUT a clipId or search_media hits); 'frames' = project frames. Use when you already have one clip's per-word timestamps.\n\nOverlapping ranges merge. Linked audio/video partners of every touched clip are cut on the same span so A/V stays in sync. Remaining clips shift left to close every gap; sync-locked tracks shift along to preserve alignment (their content isn't cut). Refuses without changing anything if a sync-locked track can't absorb the shift (e.g. it would move past frame 0). The refusal names the blocking track (e.g. \"V2\") — map it to its index via get_timeline and pass that index in ignoreSyncLockedTracks to cut anyway, leaving that track's clips in place. Returns the anchor track's post-cut layout (clip ids/frames) so you don't need to re-read.",
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
                    "ignoreSyncLockedTracks": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Track indices to exempt from sync-lock for this call only. Their clips stay put instead of shifting to close the gap. Use to get past a refusal naming a sync-locked overlay track (e.g. a text track that can't absorb the shift) when the cut doesn't touch that track's content.",
                    ],
                ],
                required: ["ranges"]
            )
        ),
        AgentTool(
            name: .setClipProperties,
            description: "Apply the same generic clip property values to one or more clips in a single undoable action. Pass any combination of durationFrames, trimStartFrame, trimEndFrame, speed, volume, opacity, transform, or blendMode (video/image clips only). For text content, typography, captions, and text animation, use update_text.\n\nNOT for preview layout — split screen, picture-in-picture, grid, sidebar, and any multi-clip canvas arrangement belong to apply_layout, which sets transform and crop together. Do not use transform here (or set_keyframes position/scale/crop) to build those layouts.\n\nAll values apply to every clip in clipIds; for per-clip differences, make separate calls. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. transform is for rare single-clip tweaks only — 0–1 normalized canvas coords, partial merge; flipHorizontal/flipVertical mirror across the axis.\n\nFor moves and start-frame changes, use move_clips. For animated values (keyframes), use set_keyframes — setting volume or opacity here clears any existing keyframe track on that property.\n\nTiming changes (durationFrames, trimStartFrame, trimEndFrame, speed) on a linked clip carry over to its linked partner so audio/video stay in sync — same as the timeline UI. Per-clip fields (volume, opacity, transform, blendMode) don't propagate. trim and speed are skipped for text partners.\n\nTiming fields (trims, durationFrames, speed) are refused on multicam clips — they would slip the clip out of sync; property fields stay editable, and angle changes go through change_cam.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to update. The property values below apply to every clip in this list.",
                        "items": ["type": "string"],
                    ],
                    "durationFrames": ["type": "integer", "description": "New duration in frames."],
                    "trimStartFrame": ["type": "integer", "description": "SOURCE-media offset, NOT a timeline frame: frames trimmed off the start of the source — measured in PROJECT frames (the timeline's fps, same units as startFrame/durationFrames; never the source's own fps). To turn a get_transcript project frame P into this clip's source offset, use trimStartFrame + (P − startFrame) × speed; setting trimStartFrame to that value makes the clip begin at P's source content."],
                    "trimEndFrame": ["type": "integer", "description": "SOURCE-media offset, NOT a timeline frame: frames trimmed off the end of the source, in PROJECT frames. Maps the same way as trimStartFrame via startFrame/speed."],
                    "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0). >1 speeds up, <1 slows down. The clip's timeline length is rescaled to keep the same source content (2x speed → half the frames), unless you also pass durationFrames to set the length explicitly."],
                    "volume": ["type": "number", "description": "Volume 0.0-1.0. Clears any existing volume keyframes."],
                    "opacity": ["type": "number", "description": "Opacity 0.0-1.0. Clears any existing opacity keyframes."],
                    "transform": [
                        "type": "object",
                        "description": "Single-clip only — not for split screen, PIP, or grid (use apply_layout). Partial transform: centerX, centerY, width, height, flipHorizontal, flipVertical; omitted fields keep current value.",
                        "properties": [
                            "centerX": ["type": "number"],
                            "centerY": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                            "flipHorizontal": ["type": "boolean", "description": "Mirror across the vertical axis."],
                            "flipVertical": ["type": "boolean", "description": "Mirror across the horizontal axis."],
                        ],
                    ],
                    "blendMode": [
                        "type": "string",
                        "enum": BlendMode.allCases.map(\.rawValue),
                        "description": "Video/image clips only. How the clip composites over the tracks below it (Premiere/Photoshop blend modes). 'normal' is the default (source-over) and clears any blend. Rejected on text/audio clips.",
                    ],
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
            name: .applyLayout,
            description: "Arrange multiple clips into a common multi-video layout (split screen, picture-in-picture, grid) in one undoable action — the fast path for composing several videos in one frame. Use this instead of hand-setting transforms and screenshot-checking alignment with inspect_timeline.\n\nYou pick a named layout and assign a clip to each of its slots; the tool computes every transform and crop so each clip FILLS its region edge-to-edge WITHOUT stretching — the source is cropped to the slot's shape (cover), like a layout template the videos are dropped into. Pass fit='fit' to letterbox the whole source inside its slot instead (no crop, may leave bars) — use only when the full frame must stay visible (e.g. a screen recording).\n\nThe crop is centered by default. When that chops off something important (a face cropped at the forehead, a subject off to one side), bias which part survives: 'anchor' is a coarse shortcut ('top' keeps the top, etc.), while anchorX/anchorY (0–1) give continuous control for in-between framing — e.g. anchorY 0.35 moves the crop only slightly toward the top, not all the way. To nudge framing after the fact, call apply_layout again with adjusted anchorX/anchorY (clipIds mode re-crops in place).\n\nTwo modes (don't mix across slots):\n• Place new clips: give each slot a 'mediaRef' (from get_media) plus top-level startFrame (default 0) and endFrame. Creates one stacked video track per slot at that time range; for PIP the inset is placed on top automatically. Video clips bring their linked audio.\n• Re-layout existing clips: give each slot 'clipIds' — one or more existing clips, all framed into that slot (handy when a track holds several sequential takes). Only transforms/crop change — timing and tracks are untouched (so existing track order decides stacking).\n\nEvery slot of the chosen layout must be filled. Layouts and their slot names:\n  • full — main\n  • side_by_side — left, right\n  • top_bottom — top, bottom\n  • pip_bottom_right / pip_bottom_left / pip_top_right / pip_top_left — main, inset\n  • grid_2x2 — top_left, top_right, bottom_left, bottom_right\n  • main_sidebar — main (70%), sidebar (30%)\n  • three_up — left, center, right",
            inputSchema: objectSchema(
                properties: [
                    "layout": [
                        "type": "string",
                        "enum": VideoLayout.allCases.map(\.rawValue),
                        "description": "Which layout template to apply.",
                    ],
                    "slots": [
                        "type": "array",
                        "description": "One entry per slot of the chosen layout. Each entry names a 'slot' and gives exactly one of 'mediaRef' (place a new clip) or 'clipIds' (re-layout existing clip(s) into that slot). Don't mix placement (mediaRef) with re-layout (clipIds) across slots.",
                        "items": objectSchema(
                            properties: [
                                "slot": ["type": "string", "description": "Slot name for the chosen layout (e.g. 'left', 'inset', 'top_right')."],
                                "mediaRef": ["type": "string", "description": "Asset ID from get_media to place into this slot. Use this OR clipIds."],
                                "clipIds": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Existing clip(s) to frame into this slot — every listed clip gets this slot's transform/crop (pass one id for a single clip, or several when a track holds sequential takes). Use this OR mediaRef. Clips sharing a slot may sit on the same track; clips in DIFFERENT slots still must not overlap on one track.",
                                ],
                                "anchor": [
                                    "type": "string",
                                    "enum": ["center", "top", "bottom", "left", "right", "top_left", "top_right", "bottom_left", "bottom_right"],
                                    "description": "Coarse shortcut for which part of the source to keep when cover-cropping (default center). For in-between framing use anchorX/anchorY instead — the named values are just shortcuts for them.",
                                ],
                                "anchorX": ["type": "number", "description": "Fine horizontal framing, 0–1: 0 keeps the left edge, 0.5 centers (default), 1 keeps the right. Only affects slots cropped horizontally. Overrides anchor's x."],
                                "anchorY": ["type": "number", "description": "Fine vertical framing, 0–1: 0 keeps the top (e.g. a forehead), 0.5 centers (default), 1 keeps the bottom. Nudge by small amounts (e.g. 0.35) to move the crop gradually. Only affects slots cropped vertically. Overrides anchor's y."],
                            ],
                            required: ["slot"]
                        ),
                    ],
                    "startFrame": ["type": "integer", "description": "Placement mode only (mediaRef slots). Project frame where the layout begins. Default 0."],
                    "endFrame": ["type": "integer", "description": "Placement mode only (mediaRef slots). The placed clips occupy [startFrame, endFrame). Required when placing new clips."],
                    "fit": [
                        "type": "string",
                        "enum": [LayoutFit.fill.rawValue, LayoutFit.fit.rawValue],
                        "description": "How each clip fills its slot. 'fill' (default) covers the slot and center-crops the source (no stretch). 'fit' letterboxes the whole source inside the slot.",
                    ],
                ],
                required: ["layout", "slots"]
            )
        ),
        AgentTool(
            name: .syncClips,
            description: "Align one or more clips to a reference clip by shifting targets on the timeline — use for dual-system sound (camera + external audio) or multicam. Default mode 'auto' aligns by embedded source timecode when both files carry one (exact, confidence 1.0), falling back to audio cross-correlation otherwise (seeded by capture dates when present); force a method with mode. referenceClipId stays put unless a target would land before frame 0, in which case the whole group shifts right together (reported as shiftedFrames). Returns offsetFrames, confidence (0–1), and method (timecode|audio) per target; refuses weak audio matches. Refused on multicam clips — a group's members are already aligned by its sync maps (manage_multicam).",
            inputSchema: objectSchema(
                properties: [
                    "referenceClipId": ["type": "string", "description": "Clip the others align to. Stays put."],
                    "targetClipId": ["type": "string", "description": "Single clip to align. Use targetClipIds for several."],
                    "targetClipIds": ["type": "array", "items": ["type": "string"], "description": "Clips to align with the reference."],
                    "mode": ["type": "string", "enum": ["auto", "audio", "timecode"], "description": "auto (default): timecode when available, else audio. audio/timecode force that method."],
                    "searchWindowSeconds": ["type": "number", "description": "Max ± offset to search in seconds, audio mode only (default 30)."],
                    "minConfidence": ["type": "number", "description": "Minimum audio correlation confidence 0–1 (default 0.5)."],
                ],
                required: ["referenceClipId"]
            )
        ),
        AgentTool(
            name: .manageMulticam,
            description: "Create or ungroup a multicam group. create syncs session media into ordinary stamped timeline clips: one program video track, one audio track per mic, and angle switches through change_cam. Use member kind angle for scratch-camera audio, mic for program audio, and both for a camera whose audio should play. Pin offsetSeconds when correlation cannot align a member. ungroup strips stamps and leaves clips in place.",
            inputSchema: objectSchema(
                properties: [
                    "create": objectSchema(
                        properties: [
                            "members": [
                                "type": "array",
                                "description": "Session source files, at least two.",
                                "items": objectSchema(
                                    properties: [
                                        "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                                        "kind": ["type": "string", "enum": ["angle", "mic", "both"], "description": "angle = camera scratch audio, mic = audio in the mix, both = camera plus program audio."],
                                        "angleLabel": ["type": "string", "description": "Handle used by change_cam. Default: file name."],
                                        "offsetSeconds": ["type": "number", "description": "Pin this member's group-clock offset instead of correlating."],
                                    ],
                                    required: ["mediaRef", "kind"]
                                ),
                            ],
                            "name": ["type": "string", "description": "Group name. Default: Multicam N."],
                            "master": ["type": "string", "description": "angleLabel or mediaRef whose audio clock defines the group. Default: first mic/both member."],
                            "startFrame": ["type": "integer", "description": "Timeline frame to place the group. Default: timeline end."],
                            "searchWindowSeconds": ["type": "number", "description": "Max ± audio sync search window, seconds (default 240)."],
                        ],
                        required: ["members"]
                    ),
                    "ungroup": objectSchema(
                        properties: [
                            "groupId": ["type": "string", "description": "Group to dissolve; its clips stay put, unstamped."],
                        ],
                        required: ["groupId"]
                    ),
                ]
            )
        ),
        AgentTool(
            name: .changeCam,
            description: "Switch a multicam group's camera angle over timeline frame ranges, full-frame or in a multi-angle layout. Batched entries are one undo step. Ranges where an angle was not recording clamp or skip. Returns switched count, optional clamps/skips/overlayClipIds, and program rows over the touched span.\n\nEach entry is EITHER {range, angle} — full-frame switch — or {range, layout, angles} — PiP/split/grid: angles fill the layout's slots in order (first = the full-frame program slot; fewer angles than slots leaves cells empty), extra angles land as synced overlay clips above the program. A later full-frame entry over the same range clears the layout. Overlay clips are ordinary group clips — restyle with set_clip_properties/apply_layout, remove with remove_clips.",
            inputSchema: objectSchema(
                properties: [
                    "groupId": ["type": "string", "description": "The multicam group (from manage_multicam create or get_timeline's multicamGroups). Or pass clipId."],
                    "clipId": ["type": "string", "description": "Any clip of the group on the active timeline."],
                    "entries": [
                        "type": "array",
                        "description": "Switches to apply, in order. Later entries win on overlap.",
                        "items": objectSchema(
                            properties: [
                                "range": ["type": "array", "items": ["type": "integer"], "description": "[startFrame, endFrame) in timeline frames."],
                                "angle": ["type": "string", "description": "angleLabel to show full-frame. Omit when using layout."],
                                "layout": ["type": "string", "description": "Multi-angle layout: side_by_side, top_bottom, pip_bottom_right, pip_bottom_left, pip_top_right, pip_top_left, grid_2x2, main_sidebar, three_up."],
                                "angles": ["type": "array", "items": ["type": "string"], "description": "angleLabels in slot order for layout; [0] is the program slot."],
                            ],
                            required: ["range"]
                        ),
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .getMulticam,
            description: "Read a multicam group: members (angleLabel, kind, offsetSeconds, confidence, which is master), the current program cut as run-length [angle, startFrame, endFrame) rows in timeline frames, and the track indexes the group occupies. Use it to learn angle labels before change_cam, or to review the cut as one program instead of piecing it together from get_timeline's clips. Window long timelines with startFrame/endFrame.",
            inputSchema: objectSchema(
                properties: [
                    "groupId": ["type": "string", "description": "The multicam group id. Or pass clipId."],
                    "clipId": ["type": "string", "description": "Any clip of the group on the active timeline."],
                    "startFrame": ["type": "integer", "description": "Optional window start for program rows."],
                    "endFrame": ["type": "integer", "description": "Optional window end (exclusive)."],
                ]
            )
        ),
        AgentTool(
            name: .undo,
            description: "Reverts the assistant's most recent timeline edit (a cut, move, trim, split, or clip/text/caption add) as one step. The recovery path when an edit went too far — e.g. a ripple_delete_ranges removed more than intended. Verify a cut first (get_transcript reflects the post-cut audio), then undo if it overshot, then retry with corrected ranges.\n\nUndoes only edits the assistant made this session, most-recent-first — it never touches the user's own manual edits, and refuses if the latest change wasn't the assistant's. After undoing, the timeline is restored to its state before that edit; the ids/frames the edit returned are no longer valid, so re-read with get_timeline or get_transcript if you'll edit again. Takes no arguments.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .getTranscript,
            description: "Returns the spoken transcript of the CURRENT timeline in project frames — the post-edit caption track in one call. Unlike inspect_media (which transcribes one source asset in isolation, in source seconds), this walks every audio/video clip on the timeline, maps each word through that clip's trim/speed/position, and concatenates in timeline order. Deleted ranges are gone by construction, so after cuts this always reflects what's actually audible — no stale results, no per-clip frame math. The app chooses cloud only when the signed-in account has enough credits for the uncached request; otherwise it uses local transcription and reports the resolved transcriptionSource in the response.\n\nReturns clips in timeline order, each with its words as compact [index, text, startFrame] rows (a word runs to the next word's start; the last word to its clip's end). Speakers, when identified, arrive as run-length turns: speakers = [[firstWordIndex, name], ...]. The index is a stable, global, 0-based position in timeline order; pass it straight to remove_words to cut that word (the intuitive path for text-based editing). Indices stay global even when scoped with clipId or paged with a window. Capped at 10000 words; page with startFrame/endFrame using nextStartFrame.\n\nFor comprehension rather than cutting — summarizing, finding a topic, take selection on long media — pass granularity='segments': sentence rows [firstWordIndex, text, start, end] at a fraction of the tokens, whose firstWordIndex jumps you back into word mode for the cut window.\n\nUse for transcript-driven edits (filler-word / dead-air removal, locating a quote, take selection) and to verify what remains after cutting. To cut, prefer remove_words (give it the indices); drop to ripple_delete_ranges only for non-word-aligned spans.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Only return words ending after this project frame. Use with the returned nextStartFrame to page a long timeline."],
                    "endFrame": ["type": "integer", "description": "Optional. Only return words starting before this project frame."],
                    "clipId": ["type": "string", "description": "Scope the transcript to a single clip — returns only what that clip says, in project frames. Answers \"what's in clip X?\" without scanning the whole timeline."],
                    "granularity": ["type": "string", "enum": ["words", "segments"], "description": "words (default) for cutting with remove_words; segments for cheap sentence-level reading — rows carry firstWordIndex to drill back into words."],
                    "language": ["type": "string", "description": "Optional BCP-47 speech language. Applies to local only; cloud auto-detects."],
                ]
            )
        ),
        AgentTool(
            name: .removeWords,
            description: "Cut speech by the word, Descript-style — the primary tool for text-based editing (filler words, flubbed sentences, dropped retakes, tightening a ramble). Pass words for precise get_transcript indices/ranges, or matches for exact filler tokens like \"um\" and \"uh\". This resolves them to frames, removes the surrounding pause so survivors don't end up double-spaced, merges adjacent removals, cuts linked A/V partners, and closes the gaps. You never deal in frame numbers — that's the whole point versus ripple_delete_ranges.\n\nWorkflow: call get_transcript, read it as prose, then pass the indices of the words to drop. Omit language by default; remove_words reuses the previous get_transcript source so cloud/local word indices stay aligned. Words across multiple clips on ONE track are handled in a single undoable action, and any linked A/V partner (e.g. the video paired with this audio) is cut automatically. Edit one track at a time: if your indices span multiple unlinked tracks (e.g. two separate mics), the call is refused — cut each track in its own call, or link the tracks into one unit first. After it runs, indices have shifted — re-read get_transcript before another remove_words.\n\nWhen to use which: words for selective edits after reading the transcript; matches for removing every exact filler token; ripple_delete_ranges only for spans that aren't word-aligned. Verify reworded retakes and sub-frame seam fragments against the word list, not a summary.",
            inputSchema: objectSchema(
                properties: [
                    "words": [
                        "type": "array",
                        "description": "Words to remove, by get_transcript index. Each element is either a single index (e.g. 42) or an inclusive [startIndex, endIndex] span (e.g. [12, 18]). Mutually exclusive with matches. Re-read after any edit.",
                        "items": ["type": ["integer", "array"]],
                    ],
                    "matches": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Exact single-word tokens to remove everywhere, case-insensitive with surrounding punctuation ignored, e.g. [\"um\", \"uh\", \"hmm\"]. Mutually exclusive with words. Avoid broad words like \"like\" unless the user explicitly wants every occurrence removed.",
                    ],
                    "cutAggressiveness": [
                        "type": "string",
                        "enum": ["tight", "balanced", "loose"],
                        "description": "How much silence to leave between the words on either side of a cut. 'tight' butts them close (snappy, can feel clipped), 'balanced' (default) keeps a natural beat, 'loose' leaves more breathing room. The removed words' own frames always go regardless.",
                    ],
                    "language": ["type": "string", "description": "Optional BCP-47 speech language for local transcription. Omit to reuse the previous get_transcript language."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .removeSilence,
            description: "Remove dead air — quiet, speech-free sections — from the timeline's audio, ripple-closing the gaps. Sections come from on-device speech detection (the same spans marked red on waveforms): non-speech runs whose level sits well below the recording's own speech level, so music beds and loud ambience are never cut, and speech-boundary slop keeps the cuts from feeling clipped. Cuts linked A/V partners and honors sync lock; the whole pass is one undoable action.\n\nUse this to tighten pacing (long pauses, dead space between takes) before or instead of word-level edits: remove_silence handles pauses, remove_words handles fillers and flubbed lines. No transcript needed. If it reports no dead air, speech analysis may still be running in the background — wait a moment and retry. Takes no arguments.",
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        AgentTool(
            name: .detectBeats,
            description: "Detect musical beats and downbeats in a media asset's audio, on-device. Returns beats and downbeats in SOURCE seconds (multiply by fps for frame values, same convention as search_media hits) plus estimated bpm. Downbeats mark bar starts — cut on downbeats for edits that land musically; beats are fine for faster montage rhythms.\n\nUse for beat-synced editing: snapping cuts to a music bed, building montages where clip boundaries hit the beat, or timing text/caption entrances to the bar. To place a cut at a beat B on a clip, the timeline frame is startFrame + (B × fps − trimStartFrame) / speed. Works on music; speech or ambience returns few or no beats. Runs locally — no subscription needed.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Audio or video asset id from get_media."],
                    "startSeconds": ["type": "number", "description": "Optional. Return only beats at or after this source-media second. The whole file is analyzed once and cached; windowing trims the response, not the work."],
                    "endSeconds": ["type": "number", "description": "Optional. Return only beats at or before this source-media second."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .addTexts,
            description: "Adds text clips as timeline layers. Omit trackIndex on every entry to create one new top video track; otherwise set trackIndex on every entry. Transform is normalized text-box center/size; center-only auto-fits, all four fields override the box. Use add_captions for spoken audio captions. Unknown fields are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Text clips to add.",
                        "items": [
                            "type": "object",
                            "properties": mergedProperties([
                                "trackIndex": ["type": "integer", "description": "Existing non-audio track. Omit on all entries to create a new top track."],
                                "startFrame": ["type": "integer", "description": "Timeline start frame."],
                                "endFrame": ["type": "integer", "description": "Occupy timeline frames [startFrame, endFrame) — copy a clip's frames pair to title exactly that span."],
                                "content": ["type": "string", "description": "Text. Supports \\n."],
                                "transform": [
                                    "type": "object",
                                    "description": "Text box. Omit for centered auto-fit; center only auto-fits size; all four override.",
                                    "properties": textBoxTransformProperties(),
                                ],
                            ], textStyleProperties(), [
                                "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Animation preset; off clears."],
                                "highlightColor": ["type": "string", "description": "Active-word hex."],
                            ]),
                            "required": ["startFrame", "endFrame", "content"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .updateText,
            description: "Updates text clips or a captionGroupId. Use for content, typography, color, outline color, background color, animation, or text-box transform. Content/typography changes auto-fit the box unless transform is passed. Unknown fields are rejected.",
            inputSchema: objectSchema(
                properties: mergedProperties([
                    "clipIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Text clip IDs. Optional if captionGroupId is given.",
                    ],
                    "captionGroupId": ["type": "string", "description": "Caption group id from get_timeline."],
                    "content": ["type": "string", "description": "Replacement text. Supports \\n."],
                    "transform": [
                        "type": "object",
                        "description": "Partial text-box transform; omitted fields keep current values.",
                        "properties": textBoxTransformProperties(),
                    ],
                ], textStyleProperties(), [
                    "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Animation preset; off clears."],
                    "highlightColor": ["type": "string", "description": "Active-word hex."],
                ]),
                required: []
            )
        ),
        AgentTool(
            name: .addCaptions,
            description: "Transcribes the timeline's spoken audio and creates styled caption text clips on their own track — no targeting needed; it finds the spoken content itself. The app uses cloud only when the signed-in account has enough credits for the uncached request; otherwise it uses local transcription. Cloud auto-detects language. Per-word animations are timed from the transcript. Returns the caption group summary (captionGroupId, clipCount, frameRange, shared style, textPreview) — restyle it later with update_text and that captionGroupId.",
            inputSchema: objectSchema(
                properties: mergedProperties([
                    "language": ["type": "string", "description": "BCP-47 speech language. Applies to local only; cloud auto-detects."],
                    "transform": [
                        "type": "object",
                        "description": "Caption box position; size is auto-fit per caption.",
                        "properties": [
                            "centerX": ["type": "number", "description": "0-1 horizontal center."],
                            "centerY": ["type": "number", "description": "0-1 vertical center."],
                        ],
                    ],
                    "textCase": ["type": "string", "enum": ["auto", "upper", "lower"], "description": "Letter case."],
                    "censorProfanity": ["type": "boolean", "description": "Mask profanity."],
                    "maxWords": ["type": "integer", "description": "Max words per caption."],
                ], textStyleProperties(), [
                    "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Caption animation preset."],
                    "highlightColor": ["type": "string", "description": "Active-word hex."],
                ])
            )
        ),
        AgentTool(
            name: .applyColor,
            description: "Author/refine a color grade on video/image clips with named controls — the colorist path, distinct from apply_effect (looks/FX). Returns the clips with their resulting grade as a `color` object — the same object get_timeline shows; pass one back via the `color` parameter to copy a grade between clips (replaces the whole grade). MERGES with the clip's current grade: only the params you pass change, the rest are preserved, so you can nudge one knob at a time (pass reset:true to start from neutral). Applies as live, editable color.* effects; non-color effects untouched. Iterate: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat. Undoable. All knobs optional. Color WHEELS use HUE (0–360°, standard) + AMOUNT per tonal zone — to push shadows teal, set shadowsHue 180 and shadowsAmount ~0.15. CURVES (master + per-channel R/G/B) give precise tone shaping — per-channel curves are tone-selective (e.g. pull the blue curve down in the highlights to tame a bright sky). HUE CURVES do secondary/qualified correction — target a source hue and shift its hue/saturation/lightness (e.g. desaturate greens, warm the skin) without a mask; pair with inspect_color's hueHistogram to find which hues are present. LUT applies a .cube film-look pack on top of the grade.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clip ids from get_timeline."],
                    "reset": ["type": "boolean", "description": "Start from neutral instead of merging onto the clip's current grade. Default false."],
                    "color": ["type": "object", "description": "A complete grade object as read from a clip's `color` key (get_timeline or an apply_color echo). Replaces the target clips' grade — the grade-copy path. Mutually exclusive with reset and individual knobs."],
                    "exposure": ["type": "number", "description": "-3…3 EV. Overall brightness in linear light."],
                    "contrast": ["type": "number", "description": "0.5…1.5 (1 = neutral)."],
                    "saturation": ["type": "number", "description": "0…2 (1 = neutral; <1 mutes)."],
                    "vibrance": ["type": "number", "description": "-1…1 (protects skin tones)."],
                    "temperature": ["type": "number", "description": "2000…11000 K. HIGHER = WARMER, lower = cooler/bluer (6500 = neutral)."],
                    "tint": ["type": "number", "description": "-100…100. Positive = green, negative = magenta."],
                    "highlights": ["type": "number", "description": "-1…1. Recover (<0) or lift (>0) highlights."],
                    "shadows": ["type": "number", "description": "-1…1. Lift (>0) or deepen (<0) shadows."],
                    "blacks": ["type": "number", "description": "-1…1. Black point. Negative deepens, positive lifts (faded look)."],
                    "whites": ["type": "number", "description": "-1…1. White point."],
                    "shadowsHue": ["type": "number", "description": "Shadow color-push hue 0–360° (0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta). Use with shadowsAmount."],
                    "shadowsAmount": ["type": "number", "description": "0…1 strength of the shadow color push (0 = neutral)."],
                    "shadowsLum": ["type": "number", "description": "-0.5…0.5 shadow lift (brightness)."],
                    "midsHue": ["type": "number", "description": "Midtone color-push hue 0–360° (see shadowsHue). Use with midsAmount."],
                    "midsAmount": ["type": "number", "description": "0…1 strength of the midtone color push."],
                    "midsGamma": ["type": "number", "description": "0.5…2 midtone brightness (gamma; 1 = neutral)."],
                    "highsHue": ["type": "number", "description": "Highlight color-push hue 0–360° (see shadowsHue). Use with highsAmount."],
                    "highsAmount": ["type": "number", "description": "0…1 strength of the highlight color push."],
                    "highsGain": ["type": "number", "description": "0.5…1.5 highlight brightness (gain; 1 = neutral)."],
                    "masterCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                    "description": "Luma tone curve as [x,y] control points in 0–1 (input→output), preserves chroma. E.g. [[0,0.06],[1,0.95]] = lifted/faded film toe."],
                    "redCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                 "description": "Red-channel tone curve, [x,y] points 0–1."],
                    "greenCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                   "description": "Green-channel tone curve, [x,y] points 0–1."],
                    "blueCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                  "description": "Blue-channel tone curve, [x,y] points 0–1. Tone-selective: e.g. [[0,0],[0.7,0.7],[1,0.85]] pulls blue only in the highlights (tames a sky) and leaves shadows."],
                    "hueCurves": [
                        "type": "object",
                        "description": "Secondary/qualified correction (Resolve-style Hue-vs-Hue/Sat/Lum). Targets replace any existing hue curve. Selectivity is ~±22° around each target hue.",
                        "properties": [
                            "targets": [
                                "type": "array",
                                "description": "One or more source-hue regions to adjust (e.g. skin at 30, sky at 210).",
                                "items": objectSchema(
                                    properties: [
                                        "targetHue": ["type": "number", "description": "Source hue to act on, 0–360° (0 red, 30 orange/skin, 60 yellow, 120 green, 180 cyan, 210 sky-blue, 240 blue, 300 magenta)."],
                                        "hueShift": ["type": "number", "description": "Rotate that hue by -30…30°."],
                                        "satScale": ["type": "number", "description": "Saturation multiplier for that hue, 0–2 (1 = neutral; 1.3 pops it, 0.6 mutes it, 0 fully desaturates)."],
                                        "lumShift": ["type": "number", "description": "Lightness shift for that hue, -0.5…0.5."],
                                    ],
                                    required: ["targetHue"]
                                ),
                            ],
                        ],
                    ],
                    "lut": [
                        "type": "object",
                        "description": "Apply a .cube 3D LUT (e.g. a film-look pack) on top of the primary grade; replaces any prior LUT. The agent does not author LUT data — pass a real file path.",
                        "properties": [
                            "path": ["type": "string", "description": "Absolute path to a .cube file (~ is expanded). Copied into project storage so it survives saves."],
                            "strength": ["type": "number", "description": "Dry/wet mix 0-1 (default 1)."],
                        ],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .applyEffect,
            description: """
            Apply non-color effects (blur, sharpen, stylize, detail, key) to video/image clips as a live, \
            editable effect stack — the looks/FX path, distinct from apply_color (grading). MERGES: each effect \
            you pass is added or updated by type; effects you don't mention are left in place. Pass enabled:false \
            to bypass one without removing it, or list its type in `remove` to delete it. Out-of-range params are \
            clamped; params you omit keep their current (or default) value. Effects render in a fixed canonical \
            order regardless of the order you pass them. Undoable. Returns the clips with their resulting \
            effects as [{type, params}] — the same shape this tool accepts, so copying effects between clips \
            is passing a clip's effects array back in.

            Available effects — type: param (range, default):
            \(Self.effectCatalog())
            """,
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clip ids from get_timeline."],
                    "effects": [
                        "type": "array",
                        "description": "Effects to add or update on the clips.",
                        "items": objectSchema(
                            properties: [
                                "type": ["type": "string", "description": "Effect type id, e.g. stylize.glow (see list above)."],
                                "params": ["type": "object", "description": "Param values keyed by name. Out-of-range values are clamped; omitted params keep their current/default value."],
                                "enabled": ["type": "boolean", "description": "Default true. false bypasses the effect without removing it."],
                            ],
                            required: ["type"]
                        ),
                    ],
                    "remove": ["type": "array", "items": ["type": "string"], "description": "Effect type ids to remove from the clips."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .inspectColor,
            description: "Measure color scopes of a timeline clip's current graded look (clipId) OR a raw media asset (mediaRef) — black/white points, % clipping, mean & per-channel levels, shadow/mid/highlight color tilt, saturation, warm-cool / green-magenta balance, and a saturation-weighted hueHistogram (12 bins of 30° from 0°/red — shows which hues are present, e.g. an orange cluster = skin, a cyan/blue cluster = sky) — and return the rendered frame too. Use this to grade by the numbers instead of eyeballing, to find hues to target with apply_color's hueCurves, or to measure footage/references before grading. clipId applies the clip's effects (graded look); mediaRef measures the raw asset. Pass a reference image/video id to also measure it and get the subject−reference GAP plus hints that map onto apply_color knobs. The loop: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat until the gap is small.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "Timeline clip to measure — returns its current GRADED look (effects applied). Provide this or mediaRef."],
                    "mediaRef": ["type": "string", "description": "Media asset id from get_media to measure RAW (no grade). Provide this or clipId."],
                    "atFrame": ["type": "integer", "description": "Optional project frame to sample a clip. Defaults to the clip's midpoint. Ignored for mediaRef."],
                    "reference": ["type": "string", "description": "Optional image/video asset id from get_media to compare against; returns its scopes + the subject−reference gap."],
                ]
            )
        ),
        AgentTool(
            name: .denoiseAudio,
            description: "Remove background noise from audio clips using an on-device speech-enhancement model (DeepFilterNet3). strength is a dry/wet mix 0-1: 0 leaves the audio untouched, 1 is fully denoised. Full strength can sound thin or over-gated on real-world recordings, so the default is 0.6. The bake runs in the background — the timeline updates automatically when it finishes; no need to poll. Pass enabled:false to turn denoise off. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Audio clip ids from get_timeline."],
                    "strength": ["type": "number", "description": "Dry/wet mix, 0–1 (default 0.6). Lower it if voices sound thin or over-compressed."],
                    "enabled": ["type": "boolean", "description": "Default true. false removes the denoise effect from the clips."],
                ],
                required: ["clipIds"]
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
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
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
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .generateAudio,
            description: "Starts an async AI audio generation or transformation. Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS converts text into speech. Music and sound-effects models generate audio from a prompt or video. Voice Cleanup isolates speech from background audio. Dubbing translates source speech while preserving speaker delivery; pass targetLanguage. For models whose inputs include audio or video, provide sourceMediaRef. Video-to-audio scoring models also accept videoSourceStartFrame+videoSourceEndFrame and place the result on the timeline automatically. Other results land in the media library for placement with add_clips. Use list_models with type='audio' to inspect inputs, category, voices, and limits. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Required for text-driven models. TTS uses it as spoken text; music and sound-effects models use it as the description. Omit for Voice Cleanup and Dubbing."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID. Use list_models with type='audio' to see options and their 'inputs'. Defaults to the first model."],
                    "voice": ["type": "string", "description": "TTS only. Voice preset name. list_models shows voicesSample (first 3) + voiceCount; any voice supported by the model is accepted. Defaults to the model's defaultVoice. Ignored by music models."],
                    "lyrics": ["type": "string", "description": "MiniMax Music only. Lyrics with optional [Verse]/[Chorus] section tags. If omitted and instrumental=false, MiniMax auto-writes lyrics from the prompt."],
                    "styleInstructions": ["type": "string", "description": "Gemini TTS only. Optional delivery instructions (e.g. 'warm and slow', 'British accent')."],
                    "instrumental": ["type": "boolean", "description": "Music models only. true = no vocals when the selected model supports it. Defaults to false."],
                    "duration": ["type": "integer", "description": "Length in seconds. ElevenLabs Music: 3–600. Sonilo text-to-music: up to 600. Video-to-audio models default to the source span; pass a value to request a different output length. Voice Cleanup and Dubbing always preserve the source length. Ignored by TTS, MiniMax, and Lyria 3 Pro."],
                    "sourceMediaRef": ["type": "string", "description": "Source audio or video asset ID for models whose inputs include audio or video. Required for Voice Cleanup and Dubbing."],
                    "targetLanguage": ["type": "string", "description": "Required for Dubbing. ISO language code such as 'es', 'fr', 'de', or 'ja'."],
                    "videoSourceStartFrame": ["type": "integer", "description": "Video-to-audio models only. Start frame (timeline) of a span to render and score — pair with videoSourceEndFrame. Use get_timeline for frame numbers; for the whole timeline use 0 to the timeline's end frame."],
                    "videoSourceEndFrame": ["type": "integer", "description": "Video-to-audio models only. End frame (exclusive) of the span to score. Must be > videoSourceStartFrame."],
                    "videoSourceMediaRef": ["type": "string", "description": "Video-to-audio models only. Score this existing video asset instead of a timeline span. Mutually exclusive with the videoSource frames."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
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
            name: .sendFeedback,
            description: "Report an agent limitation or bug to the Palmier team so they can improve the product. Use when you can't do what the user asked because a capability or tool is missing or behaves wrong, the result is clearly off, or the user is plainly hitting a rough edge. This sends directly — there is no user confirmation step — so write the report in English and PARAPHRASE in your own words: translate non-English user text to English, and never include verbatim user messages, prompts, file paths, media, transcript text, or any project content. App/OS version and your recent tool names are attached automatically. Use sparingly: at most once per distinct issue.",
            inputSchema: objectSchema(
                properties: [
                    "category": ["type": "string", "enum": ["missing_capability", "wrong_result", "confusing_ux", "failure", "suggestion"], "description": "What kind of problem this is."],
                    "summary": ["type": "string", "description": "One-line paraphrased summary of the issue. Becomes the report's subject."],
                    "details": ["type": "string", "description": "Optional. Paraphrased explanation of what the user was trying to do and what went wrong or was missing. No verbatim content."],
                    "severity": ["type": "string", "enum": ["low", "medium", "high"], "description": "Optional. How much this blocked the user."],
                ],
                required: ["category", "summary"]
            )
        ),
    ]

    /// One line per non-color effect for apply_effect's description, generated from the registry.
    private static func effectCatalog() -> String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
        return EffectRegistry.all
            .filter { !$0.id.hasPrefix("color.") }
            .map { d in
                let params = d.params.map { p in
                    "\(p.key) (\(n(p.range.lowerBound))…\(n(p.range.upperBound))\(p.unit), default \(n(p.defaultValue)))"
                }.joined(separator: ", ")
                return "• \(d.id) — \(d.displayName): \(params.isEmpty ? "no params" : params)"
            }
            .joined(separator: "\n")
    }

    /// In-app assistant only
    static let readSkill = AgentTool(
        name: .readSkill,
        description: "Load the full instructions for one of the skills listed under # Skills in your system prompt. Call this before starting a task that matches a skill's description, then follow the returned procedure. Pass the id exactly as listed.",
        inputSchema: objectSchema(
            properties: [
                "id": ["type": "string", "description": "The skill id, exactly as listed under # Skills."],
            ],
            required: ["id"]
        )
    )

    /// MCP server only
    static let getProjects = AgentTool(
        name: .getProjects,
        description: "List the user's known projects, most recently opened first: each entry's id, name, path, whether it's currently open, and whether it's the active project (the one editing tools act on). Also returns a top-level `active` (name, path) for the current project, which may not appear in the list. Call this to discover what's available before open_project, or to find out which project is active. Takes no arguments.",
        inputSchema: objectSchema()
    )

    static let openProject = AgentTool(
        name: .openProject,
        description: "Open a project and make it the active one — every editing tool then acts on it. Identify it by `name` (the natural choice when the user names a project), `id` (from get_projects), or `path` to a .palmier package. If it's already open, it's brought to front; the user sees the window change. Returns a snapshot of what you opened: fps, resolution, mediaCount, canGenerate, and the timelines list — enough to orient before get_timeline.",
        inputSchema: objectSchema(
            properties: [
                "name": ["type": "string", "description": "Project name, matched case-insensitively against known projects. Errors list candidates when ambiguous or unknown."],
                "id": ["type": "string", "description": "Project id from get_projects."],
                "path": ["type": "string", "description": "Filesystem path to a .palmier package."],
            ]
        )
    )

    static let newProject = AgentTool(
        name: .newProject,
        description: "Create a new empty project in the user's Palmier Pro folder and make it active. Fails if a project with that name already exists — pick another name. Optionally set fps / aspectRatio / quality at creation so the first clips land on the right canvas (same semantics as set_project_settings). Returns the same snapshot as open_project.",
        inputSchema: objectSchema(
            properties: [
                "name": ["type": "string", "description": "Project name (without extension). Defaults to 'Untitled Project'."],
                "fps": ["type": "integer", "description": "Optional timeline frame rate (1-120)."],
                "aspectRatio": [
                    "type": "string",
                    "enum": ["16:9", "9:16", "1:1", "4:3", "2.4:1", "9:14"],
                    "description": "Optional canvas aspect ratio.",
                ],
                "quality": [
                    "type": "string",
                    "enum": ["720p", "1080p", "2K", "4K"],
                    "description": "Optional resolution preset applied to the aspect ratio.",
                ],
            ]
        )
    )

    static let closeProject = AgentTool(
        name: .closeProject,
        description: "Save and close an open project. Omit all arguments to close the active project; or identify one by name, id (from get_projects), or path. Unsaved changes are saved first. When the active project closes, the next open project becomes active (returned as `active`) — with none left, the Home window shows and editing tools need open_project/new_project again.",
        inputSchema: objectSchema(
            properties: [
                "name": ["type": "string", "description": "Project name, matched case-insensitively. Omit everything to close the active project."],
                "id": ["type": "string", "description": "Project id from get_projects."],
                "path": ["type": "string", "description": "Filesystem path to a .palmier package."],
            ]
        )
    )

    static var mcpServer: [AgentTool] { all + [getProjects, openProject, newProject, closeProject] }
    static var inAppAgent: [AgentTool] { all + [readSkill] }

    private static func textBoxTransformProperties() -> [String: [String: Any]] {
        [
            "centerX": ["type": "number", "description": "0-1 horizontal center."],
            "centerY": ["type": "number", "description": "0-1 vertical center."],
            "width": ["type": "number", "description": "0-1 width."],
            "height": ["type": "number", "description": "0-1 height."],
        ]
    }

    private static func textStyleProperties() -> [String: [String: Any]] {
        [
            "fontName": ["type": "string", "description": "Font name."],
            "fontSize": ["type": "number", "description": "Canvas points."],
            "isBold": ["type": "boolean", "description": "Bold."],
            "isItalic": ["type": "boolean", "description": "Italic."],
            "color": ["type": "string", "description": "Text color hex."],
            "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text alignment."],
            "borderColor": ["type": "string", "description": "Text outline hex; enables outline."],
            "backgroundColor": ["type": "string", "description": "Text box fill hex; enables fill."],
        ]
    }

    private static func mergedProperties(_ chunks: [String: [String: Any]]...) -> [String: [String: Any]] {
        chunks.reduce(into: [:]) { merged, chunk in
            merged.merge(chunk) { _, new in new }
        }
    }

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
