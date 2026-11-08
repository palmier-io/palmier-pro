import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
    case getCapabilities = "get_capabilities"
    // Projects
    case manageProject = "manage_project"

    // Timelines
    case getTimeline = "get_timeline"
    case inspectTimeline = "inspect_timeline"
    case createTimeline = "create_timeline"
    case setActiveTimeline = "set_active_timeline"
    case manageMarkers = "manage_markers"
    case setProjectSettings = "set_project_settings"
    case exportProject = "export_project"
    case manageExports = "manage_exports"

    // Planning
    case planEdit = "plan_edit"
    case applyPlan = "apply_plan"

    // Media library
    case getMedia = "get_media"
    case inspectMedia = "inspect_media"
    case searchMedia = "search_media"
    case importMedia = "import_media"
    case captureFrame = "capture_frame"
    case organizeMedia = "organize_media"

    // Clips
    case manageTracks = "manage_tracks"
    case manageClipLinks = "manage_clip_links"
    case addClips = "add_clips"
    case insertClips = "insert_clips"
    case moveClips = "move_clips"
    case removeClips = "remove_clips"
    case splitClips = "split_clips"
    case rippleDeleteRanges = "ripple_delete_ranges"
    case swapClipMedia = "swap_clip_media"
    case setClipProperties = "set_clip_properties"
    case copyClipSettings = "copy_clip_settings"
    case setKeyframes = "set_keyframes"
    case applyLayout = "apply_layout"
    case crossfadeAudio = "crossfade_audio"
    case setClipSpeedRamp = "set_clip_speed_ramp"
    case qcTimeline = "qc_timeline"
    case applyStylePreset = "apply_style_preset"
    case applyMotionPreset = "apply_motion_preset"
    case manageProxies = "manage_proxies"
    case offsetAudio = "offset_audio"
    case freezeClip = "freeze_clip"
    case syncToBeats = "sync_to_beats"
    case generateThumbnail = "generate_thumbnail"
    case addOutro = "add_outro"
    case composeImage = "compose_image"
    case removeImageBackground = "remove_image_background"
    case applyTextStyle = "apply_text_style"
    case duckAudio = "duck_audio"
    case applyTransition = "apply_transition"
    case removeTransition = "remove_transition"
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
    case debreatheAudio = "debreath_audio"
    case enhanceVoice = "enhance_voice"
    case matchLoudness = "match_loudness"
    case generateDrone = "generate_drone"
    case listSpeechVoices = "list_speech_voices"
    case generateSpeech = "generate_speech"
    case findStockMedia = "find_stock_media"
    case findShotCandidates = "find_shot_candidates"

    // Generation
    case listModels = "list_models"
    case generateVideo = "generate_video"
    case generateImage = "generate_image"
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"

    // Meta
    case sendFeedback = "send_feedback"
    case readSkill = "read_skill"
    case manageSkills = "manage_skills"
}

struct AgentTool: @unchecked Sendable {
    let name: ToolName
    let description: String
    let inputSchema: [String: Any]
}

enum ToolDefinitions {
    static let all: [AgentTool] = [
        AgentTool(
            name: .getCapabilities,
            description: "Reports current application capabilities before planning footage acquisition, generation, or voice cleanup. Works without an open project. Returns per-operation status, canStart, stable refusal/preparation reasons, configured stock providers, installed speech languages, and declared chat-image support. Distinguishes build exclusions from missing credentials, models, and runtime prerequisites. Does not contact providers, download models, or edit a project; availability is checked again during execution. Re-read after settings or model changes. A chat API key never enables hosted video/image/audio generation.",
            inputSchema: ["type": "object", "additionalProperties": false]
        ),
        AgentTool(
            name: .getTimeline,
            description: "Always call at the start of a session. Returns project settings (fps, resolution, totalFrames, durationSeconds), tracks with a stable trackId, their current index (what every trackIndex parameter takes), type, and clips, plus canGenerate. If canGenerate=false, read get_capabilities or list_models availability for the actual blocker; build exclusions, account state, credits, and catalog readiness have different remedies. Local speech, drones, and stock search have independent capabilities. Clip ids are accepted by clip mutation tools; trackId is accepted by manage_tracks.\n\nEvery clip occupies frames: [start, end) — timeline frames, end exclusive, duration = end − start. gaps on a track lists its empty [start, end) spans; no gaps key means contiguous. A video clip's linked audio partner is folded into it as audio: {id, track, …} carrying only what deviates (volumeDb, effects, differing trims); the partner is not repeated on its own track, which instead reports linkedClips (its folded count). Address the audio side by its nested id.\n\nFields equal to their defaults are omitted: mediaType 'video', sourceClipType = mediaType, speed 1, volumeDb 0, opacity 1, edgeRounding 0, edgeSoftness 0, trims/fades 0, identity transform/crop, default textStyle, track muted/hidden false. Text clips never report trims. Keyframe tracks that animate nothing are shown as what they are: identity tracks are dropped, constant ones appear as the static field (e.g. crop: {left: 0.31}). A graded clip carries `color` — its grade in apply_color's own vocabulary, pasteable to other clips via apply_color's color parameter. Other effects appear as effects: [{type, params}], the exact shape apply_effect accepts.\n\nCaption clips (sharing a captionGroupId) come back per track as captionGroups summaries: clipCount, frameRange, shared style, and a textPreview — individual caption clips and their ids are NOT listed. That summary is all you need to restyle (update_text with captionGroupId) or judge coverage; the spoken words live in get_transcript. Only when you must touch individual caption clips (retime one, delete one, fix one word's style), re-read with captionDetail:true — ideally windowed — to get [clipId, startFrame, endFrame, text] rows, capped at 200 per group. Caption clips whose properties deviate from the group always appear individually in clips.\n\nmarkers contains persistent review notes with markerId, name, comment, color, startFrame, endFrame, and durationFrames. Point markers have durationFrames 0; range markers use half-open [startFrame, endFrame). Windowed reads include only markers in or intersecting the window.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Window start (inclusive); only clips intersecting [startFrame, endFrame) are returned. Omit both startFrame and endFrame for the whole timeline — never pass a zero-width window. Tracks report totalClips when the window hides some."],
                    "endFrame": ["type": "integer", "description": "Optional. Window end (exclusive); must be greater than startFrame. Omit for the whole timeline."],
                    "captionDetail": ["type": "boolean", "description": "Optional. true expands captionGroups into per-clip [clipId, startFrame, endFrame, text] rows. Combine with a window; only needed to edit individual caption clips."],
                ]
            )
        ),
        AgentTool(
            name: .inspectTimeline,
            description: "See the composited timeline — what the user actually sees in the preview at a given frame: all video tracks stacked with their transforms, opacity, crop, edge softness, edge rounding, and keyframes applied, plus text and caption overlays baked in. Use this to verify your edits landed (a PIP's position, a title's placement, layer order) — inspect_media shows the raw source asset, not the cut.\n\nFrames are project frames (from get_timeline). Pass a single startFrame for one composited frame; add endFrame to sample maxFrames evenly across [startFrame, endFrame) for a transition or sequence. Frames past content render black. Each image carries a 0–1 coordinate grid over the canvas (origin top-left) and its frame number burned into the top-left (f157). Metadata lists, per rendered frame, the clip ids visible on screen top-down (caption clips as their captionGroupId) — so what you see maps straight back to the clips to edit.",
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
            name: .manageMarkers,
            description: "Creates, updates, or deletes one persistent timeline marker. A zero duration marks one frame; a positive duration is half-open. Status tracks the review workflow: open is awaiting work, review is ready for user approval, and resolved is accepted. Set review only after applying and verifying the requested edit. Set resolved only when the user explicitly approves or requests it.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["create", "update", "delete"]],
                    "markerId": ["type": "string", "description": "Required for update/delete. From get_timeline."],
                    "name": ["type": "string"],
                    "startFrame": ["type": "integer", "description": "Timeline frame."],
                    "durationFrames": ["type": "integer", "description": "0 for a point; positive for a range."],
                    "color": ["type": "string", "description": "#RGB, #RRGGBB, or #RRGGBBAA."],
                    "comment": ["type": "string"],
                    "status": ["type": "string", "enum": ["open", "review", "resolved"]],
                ],
                required: ["action"]
            )
        ),
        AgentTool(
            name: .setProjectSettings,
            description: "Change the project's frame rate, resolution, or aspect ratio. Pass fps, explicit width+height, aspectRatio, or quality. aspectRatio accepts presets or a custom width:height value and preserves the current short-edge resolution unless quality is also supplied. Explicit width/height can't be combined with aspectRatio or quality. The timeline's existing clips are re-fitted automatically: auto-fit transforms recalculate for the new canvas size, and all frame positions/durations rescale when fps changes. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "fps": ["type": "integer", "description": "Frame rate in frames per second. Common values: 24, 25, 30, 48, 50, 60."],
                    "width": ["type": "integer", "description": "Canvas width in pixels. Requires height for an exact resolution. Mutually exclusive with aspectRatio and quality."],
                    "height": ["type": "integer", "description": "Canvas height in pixels. Requires width for an exact resolution. Mutually exclusive with aspectRatio and quality."],
                    "aspectRatio": ["type": "string", "description": "Canvas aspect ratio as width:height, such as '16:9', '3:2', or '2.39:1'. Preserves the current short edge, or uses quality when supplied. Mutually exclusive with width/height."],
                    "quality": ["type": "string", "enum": ["720p", "1080p", "2K", "4K"], "description": "Resolution quality preset — scales the short edge to the target while preserving the current (or specified) aspect ratio."],
                ]
            )
        ),
        AgentTool(
            name: .exportProject,
            description: "Queues an export from the current project using the same modes as the Export dialog. mode defaults to video. video renders H.264, H.265, or ProRes; xml writes XMEML timeline XML; fcpxml writes FCPXML; palmier writes a self-contained .palmier project package. For timeline interchange, pick the format by the target editor: Premiere Pro -> xml; DaVinci Resolve or Final Cut Pro -> fcpxml (fcpxml also carries text, transforms, crop, opacity, and keyframes that xml cannot). Video exports render edge softness and edge rounding, Palmier project exports preserve them, and xml/fcpxml interchange omits them. Omit outputPath to write a unique file to ~/Downloads. Existing direct outputPath files are overwritten by default to match the UI save flow; pass overwrite=false to refuse. Every mode returns status=started or status=queued with a jobId and destination path. Use manage_exports to check progress, warnings/results, or cancel by jobId; agent exports post a system notification on completion or failure.",
            inputSchema: objectSchema(
                properties: [
                    "mode": ["type": "string", "enum": ["video", "xml", "fcpxml", "palmier"], "description": "Optional. Default video. Use xml for Premiere Pro, fcpxml for DaVinci Resolve or Final Cut Pro."],
                    "codec": ["type": "string", "enum": ["H.264", "H.265", "ProRes"], "description": "Video mode only. Optional. Default H.264."],
                    "resolution": ["type": "string", "enum": ["720p", "1080p", "2K", "4K", "Match Timeline"], "description": "Video mode only. Optional. Default Match Timeline."],
                    "delivery": ["type": "string", "enum": ["generic", "youtube", "tiktokShorts", "instagramReels"], "description": "Video mode only. Names where the file is going, and picks the codec and size that destination expects — H.264 at 1080p for the three platforms, Match Timeline for generic. Use it instead of guessing a codec and resolution for a platform upload. An explicit codec or resolution always wins, and the receipt says which of the two applied. It cannot set a bitrate: this build hands the encode to AVFoundation and exposes no bitrate control, so do not tell the user a target bitrate was applied. If the canvas orientation does not suit the destination the receipt says so rather than silently letterboxing."],
                    "outputPath": ["type": "string", "description": "Optional. Absolute destination path. If omitted, a unique project-named file is written to ~/Downloads. If no extension is provided, the mode's extension is appended."],
                    "overwrite": ["type": "boolean", "description": "Optional. Default true, matching the UI save flow. false refuses when outputPath already exists."],
                    "fcpxmlTarget": ["type": "string", "enum": ["resolve", "fcp"], "description": "fcpxml mode only. Optional, default resolve. Davinci Resolve and Final Cut interpret crop and position values differently; pick the app the file will be imported into."],
                    "timelineId": ["type": "string", "description": "Optional. Timeline to export (from get_timeline's timelines list). Defaults to the active timeline. Not valid for palmier mode, which packages every timeline."],
                ]
            )
        ),
        AgentTool(
            name: .manageExports,
            description: "Lists or cancels exports for the current project. action=list returns newest first with jobId, filename, path, status, progress percent, and any warnings/result. action=cancel requires the exact jobId returned by export_project or manage_exports list; a waiting job is removed from the queue and an active job begins canceling. Cancel only when the user asks, or to undo an export just queued with incorrect settings. Never infer that an export is stuck from elapsed time alone.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["list", "cancel"]],
                    "jobId": ["type": "string", "description": "Required for cancel. Exact jobId from export_project or manage_exports list."],
                ],
                required: ["action"]
            )
        ),
        AgentTool(
            name: .planEdit,
            description: "Maintains one persistent edit plan with structure, source-linked script beats, shots, narration intent, timing, claims, and provenance. Supplied referenceRecipe cues adapt editorial principles; reference duration never sets output runtime. New plans start proposed on the active timeline. prepare_storyboard starts a managed production review with derived scene cards and one persistent approval owner; inspect actual selections and obtain explicit user approval of the exact revision. Managed approval requires complete available narrationIntent but not rendered audio; canApprove/approvalBlockers are separate from canProduce/production blockers. Matching recording attachment and measurement preserve approval; material intent changes revoke it. Managed local-speech attachment proof is unavailable: generic generate_speech output cannot satisfy it. Managed approval cannot be replaced by a plain status change or override visual/rights blockers. Generic plan status remains available for ordinary editing. Web candidates require HTTPS URLs, license, and attribution; managed imported selections also retain rights. No timeline edits; apply_plan(commit:true) assembles once.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["create", "read", "update", "status", "delete", "review_claims", "measure_narration", "prepare_storyboard", "read_storyboard", "review_storyboard_scene", "approve_storyboard", "cancel_production", "revise_storyboard_scene", "reorder_storyboard"], "description": "Plan operation. review_claims confirms selected facts against current ledgerRevision. measure_narration verifies attached recording bytes and never guesses missing words. prepare_storyboard/read_storyboard expose persistent revision-bound cards, narrator intent, approvalBlockers/canApprove, and production blockers/canProduce. review_storyboard_scene records actually performed full still or continuous selected-span inspection; never invent evidence. approve_storyboard requires explicit user approval of the exact revision and cannot override approval blockers; a complete available narrator can be approved before audio exists. revise_storyboard_scene updates source-linked narration and/or selected visual atomically; shared beats affect every dependent scene. reorder_storyboard moves a complete contiguous scene sequence and its narration blocks while preserving IDs; shared beats, gaps, overlaps, or split sections are refused. Material revisions revoke approval; matching recording attachment and measured timing do not. cancel_production revokes approval. No timeline edits."],
                    "planId": ["type": "string", "description": "Exact plan id from a plan_edit receipt. Required for update, status, delete, review_claims, measure_narration, and single-plan reads."],
                    "plan": [
                        "type": "object",
                        "description": "Create only. A plan draft.",
                        "properties": [
                            "planId": ["type": "string", "description": "Optional stable plan id. Omit for a generated id."],
                            "name": ["type": "string", "description": "Plan name."],
                            "goal": ["type": "string", "description": "Optional filmmaking goal."],
                            "timelineId": ["type": "string", "description": "Optional. Must be the active timeline. Omitted means the active timeline."],
                            "referenceRecipe": referenceRecipeSchema,
                            "sourceLedger": sourceLedgerSchema,
                            "scriptBeats": scriptBeatsSchema,
                            "narrationIntent": narrationIntentSchema,
                            "narration": narrationSourceSchema,
                            "sections": [
                                "type": "array",
                                "description": "Optional structural sections.",
                                "items": objectSchema(properties: [
                                    "sectionId": ["type": "string", "description": "Optional stable section id. Omit for a generated id."],
                                    "title": ["type": "string", "description": "Section title."],
                                    "summary": ["type": "string", "description": "Optional section summary."],
                                    "referenceUse": referenceUseSchema,
                                    "claimIds": claimIdsSchema,
                                    "narrationLink": sceneNarrationLinkSchema,
                                    "startFrame": ["type": "integer", "description": "Timeline frame, inclusive."],
                                    "endFrame": ["type": "integer", "description": "Timeline frame, exclusive. Must be greater than startFrame."],
                                ]),
                            ],
                            "shots": [
                                "type": "array",
                                "description": "Optional B-roll or coverage shots.",
                                "items": objectSchema(properties: [
                                    "shotId": ["type": "string", "description": "Optional stable shot id. Omit for a generated id."],
                                    "title": ["type": "string", "description": "Shot title."],
                                    "startFrame": ["type": "integer", "description": "Timeline frame, inclusive."],
                                    "endFrame": ["type": "integer", "description": "Timeline frame, exclusive. Must be greater than startFrame."],
                                    "trackId": ["type": "string", "description": "Optional existing track id."],
                                    "mediaRef": ["type": "string", "description": "Optional imported asset id. Mutually exclusive with candidateURL."],
                                    "candidateURL": ["type": "string", "description": "Optional HTTPS source that has not been imported yet. Mutually exclusive with mediaRef."],
                                    "license": ["type": "string", "description": "Required with candidateURL or for a managed storyboard's imported selection."],
                                    "attribution": ["type": "string", "description": "Required with candidateURL or for a managed storyboard's imported selection."],
                                    "sourceStartSeconds": ["type": "number", "description": "Optional selected source span, with sourceEndSeconds."],
                                    "sourceEndSeconds": ["type": "number", "description": "Optional selected source span, with sourceStartSeconds."],
                                    "notes": ["type": "string", "description": "Optional shot note."],
                                    "referenceUse": referenceUseSchema,
                                    "claimIds": claimIdsSchema,
                                    "narrationLink": sceneNarrationLinkSchema,
                                ]),
                            ],
                            "notes": ["type": "string", "description": "Optional plan notes."],
                        ],
                    ],
                    "patch": [
                        "type": "object",
                        "description": "Update only. Full replacement values for supplied name, goal, sections, shots, notes, referenceRecipe, sourceLedger, scriptBeats, narrationIntent, and narration. Preserve cited cueIds/claimIds/beat IDs or replace their uses atomically. Script, intent, or attachment changes invalidate measured timing. Script, language, start frame, exact speech delivery, or chosen recording bytes are material intent changes and revoke managed approval. Attaching the matching recording preserves approval; different bytes are refused without mutation. Changed reviewed research becomes unresolved; receipts report invalidatedClaimIds and chapter/shot/beat dependents. Use review_claims with the current revision to confirm revised evidence, not another content update.",
                        "properties": [
                            "name": ["type": "string", "description": "Replacement plan name."],
                            "goal": ["type": "string", "description": "Replacement goal."],
                            "referenceRecipe": referenceRecipeSchema,
                            "sourceLedger": sourceLedgerSchema,
                            "scriptBeats": scriptBeatsSchema,
                            "narrationIntent": narrationIntentSchema,
                            "narration": narrationSourceSchema,
                            "sections": [
                                "type": "array",
                                "description": "Complete replacement sections. Preserve existing sectionIds to keep them; omitted ids become new sections.",
                                "items": objectSchema(properties: [
                                    "sectionId": ["type": "string", "description": "Existing section id to preserve, or omit for a new section."],
                                    "title": ["type": "string", "description": "Section title."],
                                    "summary": ["type": "string", "description": "Optional section summary."],
                                    "referenceUse": referenceUseSchema,
                                    "claimIds": claimIdsSchema,
                                    "narrationLink": sceneNarrationLinkSchema,
                                    "startFrame": ["type": "integer", "description": "Timeline frame, inclusive."],
                                    "endFrame": ["type": "integer", "description": "Timeline frame, exclusive. Must be greater than startFrame."],
                                ]),
                            ],
                            "shots": [
                                "type": "array",
                                "description": "Complete replacement shots. Preserve existing shotIds to keep them; omitted ids become new shots.",
                                "items": objectSchema(properties: [
                                    "shotId": ["type": "string", "description": "Existing shot id to preserve, or omit for a new shot."],
                                    "title": ["type": "string", "description": "Shot title."],
                                    "startFrame": ["type": "integer", "description": "Timeline frame, inclusive."],
                                    "endFrame": ["type": "integer", "description": "Timeline frame, exclusive. Must be greater than startFrame."],
                                    "trackId": ["type": "string", "description": "Optional existing track id."],
                                    "mediaRef": ["type": "string", "description": "Optional imported asset id. Mutually exclusive with candidateURL."],
                                    "candidateURL": ["type": "string", "description": "Optional HTTPS source that has not been imported yet. Mutually exclusive with mediaRef."],
                                    "license": ["type": "string", "description": "Required with candidateURL or for a managed storyboard's imported selection."],
                                    "attribution": ["type": "string", "description": "Required with candidateURL or for a managed storyboard's imported selection."],
                                    "sourceStartSeconds": ["type": "number", "description": "Optional selected source span, with sourceEndSeconds."],
                                    "sourceEndSeconds": ["type": "number", "description": "Optional selected source span, with sourceStartSeconds."],
                                    "notes": ["type": "string", "description": "Optional shot note."],
                                    "referenceUse": referenceUseSchema,
                                    "claimIds": claimIdsSchema,
                                    "narrationLink": sceneNarrationLinkSchema,
                                ]),
                            ],
                            "notes": ["type": "string", "description": "Replacement plan notes."],
                        ]
                    ],
                    "status": ["type": "string", "enum": ["proposed", "approved", "ready", "applied", "superseded"], "description": "Status action only. plan_edit cannot set ready or applied."],
                    "filterStatus": ["type": "string", "enum": ["proposed", "approved", "ready", "applied", "superseded"], "description": "Read only. List only plans with this status."],
                    "limit": ["type": "integer", "description": "Read only. Plans to return, 1–100 (default 20)."],
                    "claimIds": ["type": "array", "items": ["type": "string"], "description": "review_claims only. Non-empty, unique claim IDs whose current evidence was reviewed."],
                    "ledgerRevision": ["type": "string", "description": "review_claims only. Exact sourceLedgerRevision from the plan read back for review. Rejects stale research review."],
                    "storyboardRevision": ["type": "string", "description": "Storyboard approval, inspection, or revision only. Exact revision from the board actually reviewed."],
                    "sceneId": ["type": "string", "description": "Scene inspection or revision only. Stable storyboard scene ID."],
                    "selectionRevision": ["type": "string", "description": "review_storyboard_scene only. Exact selected source/span revision from its card."],
                    "coverage": ["type": "string", "enum": ["full_still_inspection", "full_span_playback"], "description": "review_storyboard_scene only. Actual complete inspection method; sparse frames cannot certify video coverage."],
                    "reviewer": ["type": "string", "description": "review_storyboard_scene only. Identifies the person or supported temporal inspection system that actually inspected the selection."],
                    "evidence": ["type": "string", "description": "review_storyboard_scene only. Non-empty description of performed inspection, final framing, and rights evidence. Not an automatic detector certificate."],
                    "facesRevealed": ["type": "boolean", "description": "review_storyboard_scene only. Whether inspected selection reveals any person's face. True blocks approval."],
                    "rightsConfirmed": ["type": "boolean", "description": "review_storyboard_scene only. Explicit verification of selected use's license and attribution obligations. False blocks approval."],
                    "suspectedDuplicate": ["type": "boolean", "description": "review_storyboard_scene only. Unresolved suspected crop/re-encode/cross-provider duplicate. True blocks approval."],
                    "comment": ["type": "string", "description": "approve_storyboard only. Optional grouped editorial approval comment."],
                    "sceneIds": ["type": "array", "items": ["type": "string"], "maxItems": 256, "description": "reorder_storyboard only. Every current scene ID exactly once in desired order. Narration blocks move with scenes; partial sections and ambiguous ownership are refused."],
                    "beatEdits": ["type": "array", "maxItems": 256, "description": "revise_storyboard_scene only. Replace selected scene's linked beats, preserving IDs, purpose, and factual references. Omitted spokenText clears its pronunciation override. Shared beats update all dependent scenes.", "items": objectSchema(properties: [
                        "beatId": ["type": "string"], "text": ["type": "string"], "spokenText": ["type": "string"],
                    ], required: ["beatId", "text"])],
                    "visual": objectSchema(properties: [
                        "mediaRef": ["type": "string", "description": "Exact current library visual ID; never silently retargeted."],
                        "license": ["type": "string"], "attribution": ["type": "string"],
                        "sourceStartSeconds": ["type": "number", "minimum": 0],
                        "sourceEndSeconds": ["type": "number", "minimum": 0],
                    ], required: ["mediaRef", "license", "attribution"]),
                ],
                required: ["action"]
            )
        ),
        AgentTool(
            name: .applyPlan,
            description: "Validates an approved plan against the current timeline and referenced media. Managed storyboard runs also require explicit current revision approval, verified source bytes, full-selection inspection, resolved rights, and no source conflicts. commit:false (default) checks readiness without editing. commit:true assembles the planned clips and marks the plan applied as one undoable action; it refuses unresolved media or blockers. Scripts require measured, aligned narration. Linked scene ranges use resolvedTiming, not estimated frames; attached narration assembles with the shots. Changed narration files and ranges shorter than minimum readable holds block readiness. Returns added clip IDs. An already-applied plan returns noOp:true without assembling again. Do not place its shots separately after a successful commit.",
            inputSchema: objectSchema(
                properties: [
                    "planId": ["type": "string", "description": "Exact plan id from a plan_edit receipt."],
                    "commit": ["type": "boolean", "description": "Validate and assemble the approved plan as one undoable action, then mark it applied. Defaults to false (readiness check only)."],
                ],
                required: ["planId"]
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
            description: "Look at a media asset before referencing or editing it. Images: the image plus dimensions and EXIF. Video: sample frames. Audio: transcription. Video transcription is opt-in via transcript:true and is deliberately slow (full audio decode plus on-device recognition, minutes on long media) — never pass it just to see what a shot looks like; ask for it only when you actually need the words, and narrow long media with startSeconds/endSeconds. It is bounded, so a stalled decode returns a transcriptionError instead of hanging. Lottie: frames sampled evenly across the animation (over gray), plus framerate and duration — use this to verify a Lottie you wrote looks and moves right. Sampled frames and stills overlay a 0–1 coordinate grid (origin top-left). Overview storyboards do not include the grid. Transcription is sentence-level segments — [text, start, end] tuples, capped at 400 — in source seconds, or project frames when clipId is set. When capped, pass the returned nextStartSeconds as startSeconds for the next page.\n\nLong media: pass overview=true for a one-image storyboard, read the segments, then re-call with startSeconds/endSeconds to zoom — windowed calls only transcribe that span, so they are fast.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Asset ID from get_media."],
                    "clipId": ["type": "string", "description": "Optional. A clip referencing this mediaRef; transcript times come back as project frames for that clip (out-of-range entries dropped)."],
                    "maxFrames": ["type": "integer", "description": "Video and Lottie. Sample frame count (default 6, max 12)."],
                    "startSeconds": ["type": "number", "description": "Video/audio. Source-time window start; scopes frames and transcription."],
                    "endSeconds": ["type": "number", "description": "Video/audio. Window end (default: asset duration)."],
                    "wordTimestamps": ["type": "boolean", "description": "Video/audio. Add word-level [text, start, end] tuples (capped at 10000 — most clips return all words at once; narrow with startSeconds/endSeconds only for very long media). Use for word-boundary edits like filler-word removal."],
                    "overview": ["type": "boolean", "description": "Video only. One storyboard grid of visually distinct, timestamped moments instead of frames — far more coverage per token; few tiles means static footage. maxFrames ignored."],
                    "transcript": ["type": "boolean", "description": "Video only. Transcribe the audio track. Off by default because it is slow; the sampled frames are returned either way."],
                    "language": ["type": "string", "description": "Optional BCP-47 language tag of the spoken audio (e.g. 'es', 'fr', 'ja', 'zh-Hans'). Defaults to the system language. Specify when the spoken language differs from the system locale — on-device models are language-specific and will produce garbled output if the wrong language is used."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .searchMedia,
            description: "Search the media library by content: what's on screen (visual) and what's said (spoken). Visual matching is semantic and on-device — phrase the query like an image caption ('a wide shot of a harbor at sunset'), not keywords; covers videos and stills. A visual search automatically installs a missing on-device model. Spoken matching layers exact keywords over on-device semantic matching of transcript segments — quote the words said, or paraphrase them; transcripts are created automatically while indexing (and by inspect_media and add_captions), so coverage grows as indexing completes. The two groups rank independently and are never blended. Scores are uncalibrated — use them for ordering only.\n\nHits are source-second ranges (image hits have no time range). To place exactly that moment, pass [startSeconds, endSeconds] straight to add_clips as source — no unit conversion.\n\nAn `index` object appears only while it can explain missing results (status: indexing | downloadingModel | preparing | disabled | failed, with indexedAssets vs indexableAssets). modelDownloadProgress is 0...1 while downloading; modelDownloadError reports the current failure. When present, moments may be incomplete — report that instead of concluding the footage doesn't exist, and don't poll in a loop. No index key means visual search was complete. Spoken results work regardless.",
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
            description: "Imports external media into the project's library — the bridge for assets coming from other MCP servers (stock libraries, music services, web search) or local files the user already has. The 'source' object must set exactly one of: url (HTTPS only — downloaded in the background, the dominant case; max \(ToolExecutor.remoteImportMaxBytes / (1024 * 1024 * 1024)) GiB), path (absolute local file path — referenced in place and not copied into the project; may also be a directory, which is imported recursively, mirroring its subfolder structure as media folders), bytes (base64-encoded inline data — max ~15 MB of base64 ≈ 11 MB binary; use url/path for anything larger), or matte (a generated solid-color PNG). For url, type is inferred from the URL path's file extension unless source.mimeType is set as an override (needed for signed URLs whose path has no usable extension). For bytes, source.mimeType is required.\n\nSupported types and extensions: video (mov, mp4, m4v), audio (mp3, wav, aac, m4a, aiff, aifc, caf, flac), image (png, jpg, jpeg, tiff, heic), Lottie animation (json — must be a valid Lottie document, not arbitrary JSON; import locally with source.path or source.bytes), subtitle (srt, vtt — becomes a subtitle asset; place its cues as caption clips at their timecodes via add_captions subtitleMediaRef or a user drag onto the timeline; not placeable via add_clips). Anything else is rejected — the caller must transcode externally.\n\nURL imports run in the background and return {mediaRef, status:'downloading'} — poll get_media with ids:[mediaRef] until generationStatus clears, then the asset is usable in add_clips. Path, directory, bytes, and matte imports finish inline with status:'ready'. Costs nothing.",
            inputSchema: objectSchema(
                properties: [
                    "source": [
                        "type": "object",
                        "description": "Exactly one of url, path, bytes, or matte must be set. mimeType is required when bytes is set; for url it acts as a type-inference override.",
                        "properties": [
                            "url": ["type": "string", "description": "HTTPS URL. Pre-signed URLs are fine but must not expire mid-download."],
                            "path": ["type": "string", "description": "Absolute local file or directory path, readable by the Palmier process. Files are referenced in place and must remain available. A directory is imported recursively and its folder structure is replicated as media folders."],
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
                            "mimeType": ["type": "string", "description": "Required when bytes is set. Optional override for url when its path has no usable extension (e.g. signed URLs). \(ToolExecutor.acceptedMimeTypesMessage)"],
                            "origin": objectSchema(properties: [
                                "provider": ["type": "string", "enum": ["pexels", "pixabay", "openverse"]],
                                "assetId": ["type": "string", "minLength": 1, "maxLength": 256],
                                "landingPageUrl": ["type": "string", "description": "Original HTTPS source page, not a rendition URL."],
                                "sourceId": ["type": "string", "description": "Optional consistency check; pass the search hit's origin unchanged."],
                            ], required: ["provider", "assetId"]).merging([
                                "description": "For source.url only. Pass the stock hit's origin unchanged to retain original provider identity across downloads and renditions. Claimed origin is provenance, not proof of rights or uniqueness.",
                            ]) { _, value in value },
                        ],
                    ],
                    "name": ["type": "string", "description": "Display name in the library. Defaults to the filename derived from url/path, or 'Imported asset' for bytes."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'B-roll/Sunset'. Created if missing. Omit for the project root."],
                ],
                required: ["source"]
            )
        ),
        AgentTool(
            name: .captureFrame,
            description: "Capture one video frame as a full-resolution PNG media asset. Use timelineFrame to capture the active timeline's final composited image, including transforms, crop, edge softness, edge rounding, color, effects, text, and captions. Use mediaRef with sourceSeconds to capture an unedited frame directly from a source video instead. Pass the asset's durationSeconds as sourceSeconds to capture its final decodable frame. Exactly one mode is allowed. The returned mediaRef is ready for add_clips, generate_video startFrameMediaRef/endFrameMediaRef, generate_image references, or inspect_media. Every call creates one new undoable media asset.",
            inputSchema: objectSchema(
                properties: [
                    "timelineFrame": ["type": "integer", "description": "Project frame in the active timeline. Use this alone for the composited timeline image."],
                    "mediaRef": ["type": "string", "description": "Video asset ID from get_media. Use with sourceSeconds for a raw source frame."],
                    "sourceSeconds": ["type": "number", "description": "Source time in seconds for mediaRef. May equal durationSeconds to select the final decodable frame."],
                    "name": ["type": "string", "description": "Optional media-library name for the captured PNG."],
                ]
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
            description: "Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). The whole batch is one undo step.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates the needed tracks — one shared video track for visual entries (above existing visuals) and one shared audio track for audio entries (appended below existing audio, so linked dialogue on A1 stays put and music/VO land on A2+). To target existing tracks, set trackIndex on every entry. Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior.\n\nNESTING: mediaRef may also be a timelineId — the timeline is placed as a single live nested clip (mediaType 'sequence'), with a linked audio clip when the child has audio. Duration defaults to the child's full length; source and endFrame work as for video. Cycles (a timeline containing itself) and empty timelines are rejected.",
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
            name: .manageClipLinks,
            description: "Links or unlinks clips as one undoable action without moving, trimming, or aligning them. link merges the complete existing groups touched by clipIds and requires at least two clips of different media types. unlink accepts one or more members and dissolves each member's complete link group. Use unlink before independently trimming the audio or video side of a J-cut or L-cut; relink afterward when the clips should move together again.",
            inputSchema: objectSchema(
                properties: [
                    "action": [
                        "type": "string",
                        "enum": ["link", "unlink"],
                    ],
                    "clipIds": [
                        "type": "array",
                        "items": ["type": "string"],
                    ],
                ],
                required: ["action", "clipIds"]
            )
        ),
        AgentTool(
            name: .manageTracks,
            description: "Reorders, names, configures, or removes tracks in one undoable action. Prefer stable trackId selectors; numeric indexes use the order at call time. Index 0 renders on top, and reorder destinations must stay within the track's video/audio zone. Arrays run reorder → set → remove. User-authored names are returned separately from generated V1/A1 labels. Returns receipts and the resulting track order. Tracks holding multicam clips can't be removed or sync-unlocked.",
            inputSchema: objectSchema(
                properties: [
                    "reorder": [
                        "type": "array",
                        "description": "Moves, applied in order. Use to fix stacking, e.g. bring a PIP inset's track to index 0.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "trackId": ["type": "string", "description": "Stable track ID from get_timeline."],
                                "index": ["type": "integer", "description": "Track to move (0-based, current order)."],
                                "to": ["type": "integer", "description": "Exact destination index in the same type zone."],
                            ],
                            "required": ["to"],
                        ],
                    ],
                    "set": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "trackId": ["type": "string", "description": "Stable track ID from get_timeline."],
                                "index": ["type": "integer", "description": "Track to change (0-based, current order)."],
                                "muted": ["type": "boolean", "description": "Silence/unsilence the track's audio."],
                                "hidden": ["type": "boolean", "description": "Exclude/include a video track in the render."],
                                "syncLocked": ["type": "boolean", "description": "Whether ripple edits shift this track along."],
                                "name": [
                                    "type": "string",
                                    "maxLength": TrackName.maximumLength,
                                    "description": "Prefer exactly one short word with no spaces. Avoid generic suffixes: use Main, Brand, Headline, Outro, Product, Dialogue, Music, SFX, Ambience, or Foley; not Main Video, Brand Text, Outro Video, or Audio Bed. Preserve an exact user-supplied name and pass an empty string to clear it.",
                                ],
                            ],
                        ],
                    ],
                    "remove": [
                        "type": "array",
                        "description": "Tracks to remove with all their clips. Prefer {trackId}; bare integers are legacy current indexes.",
                        "items": ["type": ["integer", "object"], "properties": ["trackId": ["type": "string"]]],
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
            name: .swapClipMedia,
            description: "Replace a clip's source with another library asset while preserving its edit, timing, framing, effects, and keyframes. Linked video/audio clips that share the source are updated together. The replacement must have the same source type, contain audio when a linked audio clip needs it, and cover the current source range; extra tail remains available for trimming. Text, nested timeline, and multicam clips are refused; use change_cam for multicam.",
            inputSchema: objectSchema(
                properties: ["clipId": ["type": "string", "description": "Clip ID from get_timeline."],
                             "mediaRef": ["type": "string", "description": "Replacement asset ID from get_media."]],
                required: ["clipId", "mediaRef"]
            )
        ),
        AgentTool(
            name: .setClipProperties,
            description: "Apply the same generic clip property values to one or more clips in a single undoable action. Pass any combination of durationFrames, trimStartFrame, trimEndFrame, speed, volumeDb, opacity, fades, edgeRounding, edgeSoftness, transform, crop, or blendMode (video/image clips only). For text content, typography, captions, and text animation, use update_text.\n\nNOT for preview layout — split screen, picture-in-picture, grid, sidebar, and any multi-clip canvas arrangement belong to apply_layout, which sets transform and crop together. Do not use transform or crop here (or set_keyframes position/scale/crop) to build those layouts.\n\nAll values apply to every clip in clipIds; for per-clip differences, make separate calls. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volumeDb is −60 through +15 dB; 0 dB keeps source level and −60 dB is mute. opacity is 0.0–1.0. fadeInFrames/fadeOutFrames are clip-relative lengths; 0 clears that fade, and their sum must fit within the resulting clip duration. Fades multiply existing opacity or volume keyframes instead of replacing them: visual/text clips fade opacity, while audio clips fade gain. Fades are per-clip and don't propagate to linked media — include both the visual clip id and its nested audio.id from get_timeline to fade picture and sound together. edgeRounding and edgeSoftness are 0.0–1.0, where 1 reaches half the shorter visible edge. transform is for rare single-clip tweaks only — 0–1 normalized canvas coords, partial merge; rotation is clockwise degrees; flipHorizontal/flipVertical mirror across the axis.\n\nFor moves and start-frame changes, use move_clips. For animated values (keyframes), use set_keyframes — setting volumeDb, opacity, transform.rotation, or crop here clears any existing keyframe track on that property.\n\nTiming changes (durationFrames, trimStartFrame, trimEndFrame, speed) on a linked clip carry over to its linked partner so audio/video stay in sync — same as the timeline UI. Per-clip fields (volumeDb, opacity, fades, edgeRounding, edgeSoftness, transform, crop, blendMode) don't propagate. trim and speed are skipped for text partners.\n\nTiming fields (trims, durationFrames, speed) are refused on multicam clips — they would slip the clip out of sync; property fields stay editable, and angle changes go through change_cam.",
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
                    "volumeDb": [
                        "type": "number",
                        "minimum": VolumeScale.floorDb,
                        "maximum": VolumeScale.ceilingDb,
                        "description": "Volume in decibels from −60 through +15. 0 dB keeps source level; −60 dB is mute. Clears existing volume keyframes.",
                    ],
                    "opacity": ["type": "number", "description": "Opacity 0.0-1.0. Clears any existing opacity keyframes."],
                    "fadeInFrames": ["type": "integer", "minimum": 0, "description": "Fade length from the clip's first frame. 0 clears it. Multiplies existing opacity/volume keyframes."],
                    "fadeOutFrames": ["type": "integer", "minimum": 0, "description": "Fade length ending at the clip's last frame. 0 clears it. fadeInFrames + fadeOutFrames must not exceed the resulting clip duration."],
                    "fadeInInterpolation": ["type": "string", "enum": ["linear", "smooth"], "description": "Curve for the fade in. Omit to keep the current curve."],
                    "fadeOutInterpolation": ["type": "string", "enum": ["linear", "smooth"], "description": "Curve for the fade out. Omit to keep the current curve."],
                    "edgeRounding": ["type": "number", "minimum": 0, "maximum": 1, "description": "Video, image, Lottie, and nested timeline clips only. Uniform edge rounding from 0 (square) to 1 (half the shorter visible edge)."],
                    "edgeSoftness": ["type": "number", "minimum": 0, "maximum": 1, "description": "Video, image, Lottie, and nested timeline clips only. Edge feathering from 0 (crisp) to 1 (half the shorter visible edge)."],
                    "transform": [
                        "type": "object",
                        "description": "Single-clip only — not for split screen, PIP, or grid (use apply_layout). Partial transform; omitted fields keep current values. Static rotation uses clockwise degrees and clears rotation keyframes.",
                        "properties": [
                            "centerX": ["type": "number"],
                            "centerY": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                            "rotation": ["type": "number", "description": "Clockwise degrees."],
                            "flipHorizontal": ["type": "boolean", "description": "Mirror across the vertical axis."],
                            "flipVertical": ["type": "boolean", "description": "Mirror across the horizontal axis."],
                        ],
                    ],
                    "crop": [
                        "type": "object",
                        "description": "Static source crop for video, image, Lottie, and nested timeline clips. Partial; omitted edges keep current values. Insets are 0–1 of the source (left/top/right/bottom). All zeros restore the full source. Clears crop keyframes. Not for split screen/PIP/grid — use apply_layout.",
                        "properties": [
                            "left": ["type": "number", "description": "Inset from the source left edge, 0–1."],
                            "top": ["type": "number", "description": "Inset from the source top edge, 0–1."],
                            "right": ["type": "number", "description": "Inset from the source right edge, 0–1."],
                            "bottom": ["type": "number", "description": "Inset from the source bottom edge, 0–1."],
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
            name: .copyClipSettings,
            description: "Copy one clip's static settings to one or more clips of the same media type in a single undoable action. Use for requests such as \"make these shots look like that one,\" \"use this title style,\" or \"give these audio clips the same treatment.\"\n\nChoose exactly one target mode. targetClipIds applies to an explicit list and refuses any mismatched media type. targetTrack selects every same-type clip on one stable trackId; add range [startFrame, endFrame) to limit it to clips intersecting that part of the timeline. Track mode excludes the source and mismatched clips, returns compact matched/changed/unchanged/incompatible counts instead of clip IDs, and refuses when no compatible clips match.\n\nVideo, image, Lottie, and nested-timeline clips copy transform, crop, opacity, edge rounding/softness, blend mode, and the complete effect stack including color. Text clips copy typography/style, text animation, fill mode, position, rotation, flips, opacity, and effects; target text, word timings, and caption membership stay intact, and the box is refit to the target content. Audio clips copy volume and effects, including denoise. Settings absent from the source clear the corresponding target setting.\n\nThis does NOT copy placement, duration, trims, speed, fades, top-level keyframes, media, links, caption groups, or multicam membership. Use set_clip_properties and set_keyframes for temporal changes. Linked audio is a separate audio clip: copy it explicitly using the nested audio.id from get_timeline.",
            inputSchema: objectSchema(
                properties: [
                    "sourceClipId": ["type": "string", "description": "Clip whose current static settings are copied."],
                    "targetClipIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Explicit destination clips. Every target must have the same mediaType as the source. Use this or targetTrack, not both.",
                    ],
                    "targetTrack": objectSchema(
                        properties: [
                            "trackId": ["type": "string", "description": "Stable trackId from get_timeline."],
                            "range": [
                                "type": "array",
                                "items": ["type": "integer"],
                                "minItems": 2,
                                "maxItems": 2,
                                "description": "Optional [startFrame, endFrame) timeline range. Only intersecting clips are considered; omit for the whole track.",
                            ],
                        ],
                        required: ["trackId"]
                    ),
                ],
                required: ["sourceClipId"]
            )
        ),
        AgentTool(
            name: .setKeyframes,
            description: "Set animated keyframes on one property of one clip. Replaces the existing keyframe track for that property (pass an empty array to clear). Frames are CLIP-RELATIVE offsets (0 = first frame of the clip), so keyframes follow the clip when it moves. Rows are sorted by frame internally and the LAST row for any duplicate frame wins. Values must be finite numbers. Each row is `[frame, ...values, interp?]` where interp ∈ {linear, hold, smooth} (default smooth).\n\nProperties and their value layouts:\n  • volumeDb `[frame, decibels]` — −60 through +15 dB; 0 dB keeps source level and −60 dB is mute\n  • opacity `[frame, value]` — value 0.0–1.0\n  • rotation `[frame, degrees]` — clockwise degrees\n  • position `[frame, topLeftX, topLeftY]` — TOP-LEFT corner in 0–1 normalized canvas coords. NOT the center. (Default static transform centers a full-canvas clip, so top-left of the static is (0, 0); a centered half-size clip has top-left (0.25, 0.25).)\n  • scale `[frame, width, height]` — clip's normalized width and height in 0–1 canvas coords (1.0 = fills the canvas axis), NOT a scale factor. Text clips use this same track; use matching width/height ratios for uniform text scale.\n  • crop `[frame, top, right, bottom, left]` — animated side insets in 0–1 of the source media. Constant crop belongs on set_clip_properties.\n  • blur `[frame, radius]` — whole-layer Gaussian blur from 0–100 px; supported by visual clips including video, images, text, and nested timelines.\n\nMotion keyframes (position/scale/rotation) override the static `transform` value when active.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip ID."],
                    "property": [
                        "type": "string",
                        "enum": ["volumeDb", "opacity", "rotation", "position", "scale", "crop", "blur"],
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
            name: .generateThumbnail,
            description: "Renders a poster frame for the timeline and writes it as its own image file, for YouTube or social upload. This is NOT part of the video: nothing is added to the timeline, no clip is created, and the video is not modified in any way. The image is a separate JPEG you upload alongside the export.\n\nPresets carry each platform's real spec: youtube (1280x720, under 2 MB), vertical (1080x1920 for Shorts/Reels/TikTok), square (1080x1080), or timeline (the project's own canvas cropped to 16:9). A preset other than timeline crops the picture to fit and leaves the video untouched.\n\ntitle and subtitle are drawn ONTO THE IMAGE with a scrim, so the words stay legible over a busy frame — use a short punchy headline, not a sentence, and check the result before uploading. Pass title alone for a clean poster.\n\nOmit frame to have it pick one: it samples across the timeline and chooses the frame with the most contrast and the least clipping, because that is the most legible at a glance. That is a legibility heuristic, not a judgement about which shot tells the story best — pass frame when you already know. The receipt always says which frame was used and whether it was chosen.\n\nUse it whenever a video is going to be published somewhere with a poster image.",
            inputSchema: objectSchema(
                properties: [
                    "preset": ["type": "string", "enum": ["youtube", "vertical", "square", "timeline"], "description": "Target shape and file budget. Default youtube."],
                    "frame": ["type": "integer", "description": "Timeline frame to use. Omit to let it choose the most legible frame."],
                    "title": ["type": "string", "description": "Headline drawn onto the image. Short — three to six words."],
                    "subtitle": ["type": "string", "description": "Secondary line under the headline."],
                    "placement": ["type": "string", "enum": ["bottomLeft", "bottomCenter", "centerLeft", "center"], "description": "Where the words sit. Default bottomLeft."],
                    "titleScale": ["type": "number", "description": "Headline size as a fraction of the frame's long edge (default 0.11)."],
                    "scrim": ["type": "boolean", "description": "Darken behind the words so light text stays legible. Default true."],
                    "path": ["type": "string", "description": "Absolute directory to write into. Defaults to a thumbnails folder beside the project package."],
                    "fileName": ["type": "string", "description": "File name, with or without a .jpg extension. Default thumbnail.jpg."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .offsetAudio,
            description: "Offsets a linked video and audio pair across their cut, in one undoable step. This is the J-cut and L-cut. A POSITIVE offsetFrames is a J-cut: the next shot's audio starts before its picture, so the viewer hears where you are going before they see it — use it to lead into a reveal, a location change, or a line that sets up the cutaway. A NEGATIVE offsetFrames is an L-cut: the outgoing audio runs on over the incoming picture, which carries the sentence across the cut and is the standard way to put B-roll under a talking head without losing the thought. Only works on a linked pair: add_clips creates one automatically for media that has audio, and manage_clip_links links a separately placed audio clip. The link stays intact, so the pair still travels together when you move it. Name only the video clip. clear:true locks picture and sound back together. Do not build a J-cut by unlinking, moving and relinking — that is three undo entries for one editorial idea and it leaves a broken pair if it fails part way.",
            inputSchema: objectSchema(
                properties: [
                    "videoClipId": ["type": "string", "description": "The video clip of the linked pair."],
                    "offsetFrames": ["type": "integer", "description": "Positive = J-cut (audio leads the picture). Negative = L-cut (audio holds past the picture). Must be shorter than the clip so both sides still overlap."],
                    "clear": ["type": "boolean", "description": "Lock picture and sound back together."],
                ],
                required: ["videoClipId"]
            )
        ),
        AgentTool(
            name: .freezeClip,
            description: "Holds one frame of a clip for a chosen number of frames, as one undoable step — the freeze frame that punctuates a joke, isolates a detail, or lets a graphic land. The hold sits at the clip's head, so this is the freeze-on-the-cut: put the clip at the beat and the picture stops there. Audio under the frozen picture keeps playing, which is what makes it usable over speech. This is the correct tool for a hold; do not fake it with an extremely slow speed ramp, which needs a hundred times the source and will not hold cleanly. It also freezes a still in place under a graphic: pass a clip on an upper track and it becomes a freeze over whatever is beneath.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "Clip to freeze. Its picture holds; its audio continues."],
                    "freezeFrames": ["type": "integer", "description": "How many frames to hold the picture for. 8-20 reads as a beat; more is a held tableau."],
                    "atFrame": ["type": "integer", "description": "Which clip-relative source frame the hold shows. Defaults to 0. The hold itself always sits at the clip's head, so this picks the picture, not the position."],
                ],
                required: ["clipId", "freezeFrames"]
            )
        ),
        AgentTool(
            name: .syncToBeats,
            description: "Places cut points and effects on the music's actual beats, with snapping — the montage and beat-sync operation. detect_beats reports beats; this acts on them, so the Agent does not have to convert seconds to frames itself or risk a cut landing between beats. Use downbeats (bar starts) for the structure of a montage and plain beats for fast cutting; cut on downbeats, not on every beat, or it reads mechanical. Each entry is placed at the Nth beat, and snapFrames (default 2) lets a requested beat fall slightly early or late when the music drifts. The receipt gives you the frame each one actually landed on, so a follow-up effect can sit exactly on the cut.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "The music asset to read beats from, as returned by detect_beats."],
                    "clipId": ["type": "string", "description": "Clip to cut at those beats. Split it into the resulting sections in one undoable step."],
                    "beats": ["type": "array", "items": ["type": "integer"], "description": "Beat or downbeat indices within the clip, 0-based. Omit to cut on every downbeat in range."],
                    "useDownbeats": ["type": "boolean", "description": "Treat the indices as downbeat (bar) numbers instead of beats. Default false."],
                    "snapFrames": ["type": "integer", "description": "How far a beat may be moved to fit the clip's actual content. Default 2; 0 disables snapping so beats are used exactly."],
                ],
                required: ["mediaRef", "clipId"]
            )
        ),
        AgentTool(
            name: .manageProxies,
            description: "Builds preview proxies for large source media, or clears them. Reach for this when the user says the timeline is stuttery, scrubbing lags, or the machine is struggling with 4K/8K footage — not for editing quality, because a proxy is a preview stand-in and never touches a master render. Call it with no arguments first to see which assets are large enough to be worth proxying and which already have one, then pass generate for the ones that matter. Each entry names a mediaRef or the clipIds that use it. Transcoding is off the main thread, writes to a staging file, and is reported per asset, so a failure on one does not hide the others. Sources smaller than the threshold are refused rather than wasted on. Remove clears a proxy; the original is always still the source of truth. Long-running: one large file can take minutes.",
            inputSchema: objectSchema(
                properties: [
                    "generate": ["type": "array", "description": "Proxies to build. Each entry needs mediaRef or clipIds.", "items": ["type": "object", "properties": ["mediaRef": ["type": "string"], "clipIds": ["type": "array", "items": ["type": "string"]]]]],
                    "remove": ["type": "array", "description": "Proxies to delete. Each entry needs mediaRef or clipIds.", "items": ["type": "object", "properties": ["mediaRef": ["type": "string"], "clipIds": ["type": "array", "items": ["type": "string"]]]]],
                    "list": ["type": "boolean", "description": "Report existing proxies and the assets large enough to be worth one. Default true when neither generate nor remove is given."],
                    "longEdge": ["type": "integer", "enum": [480, 540, 720, 1080], "description": "Proxy long edge. 540 is the default and the safest on a slow machine; 1080 is for high-resolution sources. Changing it rebuilds affected proxies."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .applyTextStyle,
            description: "Restyles text with a named type style, in one undo step. This is how titles stop looking placed: font, weight, size, tracking, case, alignment and the legibility treatment are the decisions that should not vary between clips, and a preset fixes them once. Presets: title is a condensed poster face set once per piece, low in frame to clear a face; lowerThird is a small set-left name or role over an interview with a scrim behind it; caption is maximum legibility for burned-in subtitles; kicker is the small wide-tracked label above a title; credit is an end-credit line with a thin dark edge; elegant is a serif with ceremony; technical is monospaced for timecode and data, so digits do not shift; social is heavy all-caps for short-form hooks. Sizes are a fraction of canvas height, so one preset reads the same on 16:9 and 9:16. Pass clipIds, or captionGroupId to restyle a whole caption track as one unit — that is one undo step, not one per cue. fontName, fontSize, color and alignment override the preset where you need them to. applyPosition:true also places the text at the preset's position, clamped clear of the platform interface when you pass platform. A preset changes type only: it does not animate, add fill, or change timing.",
            inputSchema: objectSchema(
                properties: [
                    "preset": ["type": "string", "enum": ["title", "lowerThird", "caption", "kicker", "credit", "elegant", "technical", "social"], "description": "The named type style to apply."],
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Text clips to style. Short ids from get_timeline are accepted."],
                    "captionGroupId": ["type": "string", "description": "Restyle a whole caption track as one unit. Takes precedence over nothing; combine with clipIds if needed."],
                    "fontName": ["type": "string", "description": "Override the preset's face. Every bundled face is safe."],
                    "fontSize": ["type": "number", "minimum": 12, "maximum": 300, "description": "Absolute size in canvas points, overriding the preset's ratio."],
                    "color": ["type": "string", "description": "Override the text colour, e.g. '#F5F5F5'."],
                    "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Override horizontal alignment."],
                    "applyPosition": ["type": "boolean", "description": "Also place the text at the preset's position. Default false: moving type someone has already positioned is a separate decision."],
                    "platform": ["type": "string", "enum": ["generic", "youtube", "tiktokShorts", "instagramReels"], "description": "Destination, so a requested position clears the platform's interface. Default generic."],
                ],
                required: ["preset"]
            )
        ),
        AgentTool(
            name: .removeImageBackground,
            description: "Cuts a subject out of a still image, on this machine, and files the cutout in the library as a normal asset — a product shot on a plain backdrop, a person against a flat wall, a logo pulled off a mock-up. Vision runs entirely locally: no model is downloaded and nothing leaves the device. mode subject finds any distinct foreground subject; person uses a dedicated person model and usually gives a cleaner edge on people, refusing when no person is found. The background is left transparent so the cutout composites over anything; pass fillHex to flatten onto a solid colour instead, which is what you want for a product image on white. feather softens the cutout edge, 0 to 8, default 1.5. The result is placed with add_clips like any other image. Be honest about the limits: this is subject segmentation, not a matting network, so hair, fur and fine edges come out rough and it fails outright when there is no clear subject. For keyed footage or a green screen, use the chroma key effect instead — it is far more reliable. Report a low subjectCoverage as a sign the cutout is probably wrong rather than presenting it as clean.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "The image to cut out. Must be a still image; use the chroma key effect for video."],
                    "mode": ["type": "string", "enum": ["subject", "person"], "description": "subject finds any distinct foreground object; person uses the person model and gives a cleaner edge on people. Default subject."],
                    "feather": ["type": "number", "minimum": 0, "maximum": 8, "description": "Softens the cutout edge. As a percentage of the image's long edge. Default 1.5; 0 leaves Vision's own edge."],
                    "fillHex": ["type": "string", "description": "Flatten onto this solid colour, e.g. '#FFFFFF' for white. Omit to keep the background transparent."],
                    "name": ["type": "string", "description": "Name for the cutout in the library."],
                    "folderId": ["type": "string", "description": "Library folder to file it under."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .composeImage,
            description: "Builds ONE image out of several of this project's own frames and stills, entirely locally — a mood board, a contact sheet, a poster frame, a title card. Nothing is generated or downloaded: it arranges real pictures from the edit, so use it to assemble what you already shot rather than to invent imagery it does not contain. Give query to let the visual index find the matching shots, or mediaRefs to choose them yourself; both may be combined. layout grid is even tiles and suits contact sheets, heroStrip puts one image large above a strip and suits posters, row and column are for short runs. preset picks the output shape: youtube 1280x720, vertical 1080x1920 for Shorts/Reels/TikTok, square 1080x1080, timeline for the project's own canvas. headline and subline draw onto the image with the same lettering a thumbnail uses, so the two look identical. The result is a normal media asset in the library — pass addToTimeline:true to place it in the same step. It never touches the timeline otherwise. This is assembly, not synthesis: it cannot draw a picture of something absent from the project, and you should not describe the output as AI-generated.",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "Text to match against the visual index, e.g. \"sunset over water\". Returns the best-scoring frames and stills."],
                    "mediaRefs": ["type": "array", "items": ["type": "string"], "description": "Explicit source assets. Images are used as-is; video contributes a frame. Combined with query, retrieval comes first."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 12, "description": "How many sources retrieval may contribute. Default 6."],
                    "layout": ["type": "string", "enum": ["grid", "heroStrip", "row", "column"], "description": "grid even tiles (contact sheets, mood boards); heroStrip one large image above a strip (posters); row or column for short runs. Default grid."],
                    "preset": ["type": "string", "enum": ["youtube", "vertical", "square", "timeline"], "description": "Output shape. vertical is 1080x1920 for Shorts, Reels and TikTok. Default youtube."],
                    "headline": ["type": "string", "description": "Large text drawn onto the image."],
                    "subline": ["type": "string", "description": "Secondary line under the headline."],
                    "textPlacement": ["type": "string", "enum": ["bottomLeft", "bottomCenter", "centerLeft", "center"], "description": "Where the text sits. Default bottomLeft."],
                    "scrim": ["type": "boolean", "description": "Darken behind the text so it stays legible over a bright frame. Default true."],
                    "name": ["type": "string", "description": "Name for the image in the library. Defaults to the query."],
                    "folderId": ["type": "string", "description": "Library folder to file it under."],
                    "addToTimeline": ["type": "boolean", "description": "Place the composed image on the timeline in the same step. Default false."],
                    "startFrame": ["type": "integer", "description": "Where to place it when addToTimeline is true. Defaults to the start of the timeline."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .addOutro,
            description: "Builds the end of the film — rolling end credits, a subscribe card, or both — in one undoable step. Use this instead of building the sequence out of text clips and keyframes by hand, because the roll has to start clear of the bottom edge and exit clear of the top one, fade in and out, and land inside the platform's end-screen window; that arithmetic belongs here, not in the Agent. Give credits as a list of name/role pairs and they become a single centred roll that travels upward at a constant rate with a fade envelope. Give subscribe with a channel and handle for a held call-to-action card, kind 'subscribe' to ask or 'thanks' to acknowledge an existing subscriber. The picture keeps playing under the words — there is no held-still option, because a freeze can only hold a lead-in, not a whole tail. Platform 'youtube' enforces the 5-20 second end-screen window and will refuse a duration outside it rather than quietly producing something YouTube rejects. The outro occupies the tail of the existing edit rather than extending past it, so nothing you have already cut moves. This draws the visual card only: YouTube's clickable subscribe and video elements are attached at upload in YouTube Studio, so tell the user to add the click targets there. If they want attribution for stock or music, pass it as credits.",
            inputSchema: objectSchema(
                properties: [
                    "credits": ["type": "array", "description": "Credit lines for the roll. Each entry needs a name and may have a role. Omit for a subscribe card only."],
                    "subscribe": ["type": "object", "description": "Subscribe card. Omit for credits only.", "properties": [
                        "channel": ["type": "string", "description": "Channel or creator name shown on the card."],
                        "handle": ["type": "string", "description": "Handle such as @name, shown after the channel."],
                        "kind": ["type": "string", "enum": ["subscribe", "thanks"], "description": "'subscribe' asks for a subscription; 'thanks' acknowledges one. Default subscribe."],
                    ]],
                    "durationFrames": ["type": "integer", "description": "How long the outro runs. Default 300 (10s at 30fps). A roll needs roughly 12 frames per credit line; credits plus a card need at least 180. YouTube accepts only 150-600."],
                    "platform": ["type": "string", "enum": ["generic", "youtube"], "description": "'youtube' enforces the 5-20 second end-screen window. Default generic."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .applyStylePreset,
            description: "Gives clips a named look in one undoable step, instead of you dialling in twenty knobs per shot. This is how a whole cut ends up looking like it was graded on purpose. Presets: documentary (honest and unobtrusive, for interviews and archival); cinematic (teal shadows against warm skin, soft S-curve, for narrative and trailers); travelVlog (bright, warm, open shadows, for travel and real estate); warmFilm (faded toe and warm whites, for nostalgia); noir (near-monochrome and hard, for stylised drama); cleanCorporate (neutral and even, so it never competes with on-screen text); socialPunch (saturated and contrasty, for short-form that has to win attention in a second). Defaults to every video and image clip; pass clipIds to grade a subset. It replaces each clip's existing grade, so read get_timeline first if a hand-made grade is already there. A look is COLOR ONLY — it does not add music, transitions, fades or pacing, so decide those separately. When one shot needs to differ, nudge it with apply_color rather than reaching for a second preset. The receipt returns each clip's resulting grade in apply_color's own vocabulary, so it is pasteable and adjustable.",
            inputSchema: objectSchema(
                properties: [
                    "preset": ["type": "string", "enum": ["documentary", "cinematic", "travelVlog", "warmFilm", "noir", "cleanCorporate", "socialPunch"], "description": "The look to apply."],
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clips to grade. Defaults to every video and image clip."],
                ],
                required: ["preset"]
            )
        ),
        AgentTool(
            name: .applyMotionPreset,
            description: "Applies one restrained editor-native motion treatment to visual clips as one undoable action. fadeIn reveals without moving; slideUp combines a short upward entrance with opacity; punchIn uses a short scale-and-opacity entrance for emphasis; gentlePush adds a slow six-percent push across the whole clip. These presets write normal position, scale, and opacity keyframes, so preview and export use the same renderer. Existing keyframes are protected unless overwrite=true. Use one motivated treatment consistently; do not apply motion to every cut by default.",
            inputSchema: objectSchema(
                properties: [
                    "preset": ["type": "string", "enum": ["fadeIn", "slideUp", "punchIn", "gentlePush"]],
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Visual clips to animate."],
                    "durationFrames": ["type": "integer", "minimum": 2, "description": "Entrance duration for fadeIn, slideUp, and punchIn. Omit for a restrained default. gentlePush always spans the clip."],
                    "overwrite": ["type": "boolean", "description": "Replace keyframes owned by this preset. Default false."],
                ],
                required: ["preset", "clipIds"]
            )
        ),
        AgentTool(
            name: .qcTimeline,
            description: "Checks the whole timeline for problems and returns them as a list. Read-only: it never changes anything. Run it before declaring an edit done, and after any large batch of changes. It finds missing or unreadable media, clips that overlap on one track, gaps at a track's head or tail, audio that cuts in or out without a fade, speed that reads past the end of the media, transitions left over from deleted clips, and tracks hidden from the render. Each finding carries the clipId, the frames it applies to, and the tool that would fix it. visualIdentity separately checks retained source identities across visible nested and overlay occurrences, coalesces uninterrupted same-source splits, and reports reuse and unresolved identities/derivative lineage. It does not rehash files, compare perceptual similarity, or inspect faces; deliveryVerified is always false. Rejects state changes during identity review. It does not judge creative intent. pass covers structural findings at the requested severity only, not visual uniqueness or delivery approval.",
            inputSchema: objectSchema(
                properties: [
                    "severity": ["type": "string", "enum": ["error", "warning"], "description": "Lowest severity to report. Default warning, which reports both. Pass error to see only what will actually break."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .setClipSpeedRamp,
            description: "Ramps a clip's speed over its duration, as one undo step. Use it for the slow-into-fast push at the end of a highlight, the freeze-then-accelerate snap, or easing a time-lapse so it does not start at a dead stop. A ramp keeps the clip's timeline length and changes how much source it reads, so everything after the cut stays where it is — unlike set_clip_properties speed, which rescales the length to keep the same source. Frames are clip-relative and must increase; the first point is the clip's start rate. This is the tool for pacing and emphasis. set_clip_properties speed remains the right tool for a constant rate. Not for nested timelines, which have no source to re-time. pass clear:true to drop the ramp and go back to one constant speed.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "Clip to re-time."],
                    "points": [
                        "type": "array",
                        "description": "Speed ramp, at least 2 points, frames increasing and within 0…durationFrames.",
                        "items": ["type": "object", "properties": [
                            "frame": ["type": "integer", "description": "Clip-relative timeline frame."],
                            "speed": ["type": "number", "description": "Rate at that frame. >1 speeds up, <1 slows down."],
                        ], "required": ["frame", "speed"]],
                    ],
                    "clear": ["type": "boolean", "description": "Remove the ramp and return to one constant speed."],
                ],
                required: ["clipId"]
            )
        ),
        AgentTool(
            name: .crossfadeAudio,
            description: "Crossfades two adjacent audio clips on the same track, as one undo step. Use for dialogue-to-dialogue and music-to-music edits at a cut, and to kill a click on a butt splice. curve 'smooth' (default) and 'linear' write the clips' own fade ramps, so the UI keeps showing fade handles; 'equalPower' writes a sampled volume envelope instead, which holds perceived loudness through the overlap where a linear fade dips about 3 dB. The two clips must meet exactly — no gap, no overlap. Duration must fit inside both clips. equalPower refuses if either clip already has a fade on the edge it needs; clear that with set_clip_properties or use smooth. Set fadeInFrames/fadeOutFrames to 0 beforehand if the clips should end hard instead.",
            inputSchema: objectSchema(
                properties: [
                    "outgoingClipId": ["type": "string", "description": "Clip that plays first; its tail is faded out."],
                    "incomingClipId": ["type": "string", "description": "Clip that plays second; it must start exactly where the outgoing clip ends."],
                    "durationFrames": ["type": "integer", "description": "Crossfade length in frames (default 12). Fits inside both clips."],
                    "curve": ["type": "string", "enum": ["linear", "smooth", "equalPower"], "description": "Ramp shape. Default smooth."],
                ],
                required: ["outgoingClipId", "incomingClipId"]
            )
        ),
        AgentTool(
            name: .duckAudio,
            description: "Lowers a music or ambience bed under whatever dialogue is playing, as one undo step. Speech regions are found with on-device voice-activity detection on the source clips, then written as a volume envelope on the bed with attack, hold and release ramps. This is how you get a mix a viewer can follow: bed down while people talk, back up in the gaps. bedClipId is the clip to duck — a music bed, ambience or a room tone. sourceClipIds defaults to every other audio clip overlapping the bed; list them to duck under specific dialogue only, for example one speaker. Refuses when the bed already has volume keyframes, so pass overwrite:true to replace an existing envelope rather than silently stacking on it. When speech detection is unavailable the whole source clip is treated as speech and the receipt says speechDetection:unavailable — check it, because the bed then stays down across all of that clip. The envelope is baked keyframes: later dialogue edits do not re-derive it, re-run duck_audio to re-fit. Undo removes the whole envelope in one step.",
            inputSchema: objectSchema(
                properties: [
                    "bedClipId": ["type": "string", "description": "The clip whose volume is lowered: music bed, ambience or room tone."],
                    "sourceClipIds": ["type": "array", "items": ["type": "string"], "description": "Dialogue clips that trigger the duck. Defaults to every other audio clip overlapping the bed."],
                    "duckDb": ["type": "number", "description": "Gain below the bed's own level while speech plays. Negative; -12 is a natural default."],
                    "attackFrames": ["type": "integer", "description": "Frames from speech onset to full duck (default 6)."],
                    "holdFrames": ["type": "integer", "description": "Extra frames held down after speech ends (default 6)."],
                    "releaseFrames": ["type": "integer", "description": "Frames from speech offset back to bed level (default 18)."],
                    "mergeGapFrames": ["type": "integer", "description": "Speech closer than this is one span, so a pause between words does not pump the bed (default 12)."],
                    "overwrite": ["type": "boolean", "description": "Replace an existing volume envelope on the bed instead of refusing."],
                ],
                required: ["bedClipId"]
            )
        ),
        AgentTool(
            name: .applyLayout,
            description: "Arrange multiple clips into a common multi-video layout (split screen, picture-in-picture, grid) in one undoable action — the fast path for composing several videos in one frame. Use this instead of hand-setting transforms and screenshot-checking alignment with inspect_timeline.\n\nYou pick a named layout and assign a clip to each of its slots; the tool computes every transform and crop so each clip FILLS its region edge-to-edge WITHOUT stretching — the source is cropped to the slot's shape (cover), like a layout template the videos are dropped into. Pass fit='fit' to letterbox the whole source inside its slot instead (no crop, may leave bars) — use only when the full frame must stay visible (e.g. a screen recording).\n\nThe crop is centered by default. When that chops off something important (a face cropped at the forehead, a subject off to one side), bias which part survives: 'anchor' is a coarse shortcut ('top' keeps the top, etc.), while anchorX/anchorY (0–1) give continuous control for in-between framing — e.g. anchorY 0.35 moves the crop only slightly toward the top, not all the way. To nudge framing after the fact, call apply_layout again with adjusted anchorX/anchorY (clipIds mode re-crops in place).\n\nTwo modes (don't mix across slots):\n• Place new clips: give each slot a 'mediaRef' (media asset from get_media, or a timelineId to nest) plus top-level startFrame (default 0) and endFrame. Creates one stacked video track per slot at that time range; for PIP the inset is placed on top automatically. Video and nested-timeline clips bring their linked audio.\n• Re-layout existing clips: give each slot 'clipIds' — one or more existing clips (video, image, or nested timeline / mediaType 'sequence'), all framed into that slot (handy when a track holds several sequential takes). Only transforms/crop change — timing and tracks are untouched (so existing track order decides stacking).\n\nEvery slot of the chosen layout must be filled. Layouts and their slot names:\n  • full — main\n  • side_by_side — left, right\n  • top_bottom — top, bottom\n  • pip_bottom_right / pip_bottom_left / pip_top_right / pip_top_left — main, inset\n  • grid_2x2 / grid_3x3 / grid_4x4 — equal cells named rNcN, counting from the TOP-LEFT: row 1 is the top row, column 1 is the left column. So r1c1 is top-left, a 3x3's middle is r2c2, and a 3x3's bottom-right is r3c3\n  • main_sidebar — main (70%), sidebar (30%)\n  • three_up — left, center, right (three vertical columns)\n  • three_stack — top, middle, bottom (three horizontal rows)",
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
                                "slot": ["type": "string", "description": "Slot name for the chosen layout (e.g. 'left', 'inset', or 'r1c1' for the top-left grid cell)."],
                                "mediaRef": ["type": "string", "description": "Asset ID from get_media, or a timelineId to nest as a sequence clip. Use this OR clipIds."],
                                "clipIds": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Existing clip(s) to frame into this slot — video, image, or nested timeline (mediaType 'sequence'). Every listed clip gets this slot's transform/crop (pass one id for a single clip, or several when a track holds sequential takes). Use this OR mediaRef. Clips sharing a slot may sit on the same track; clips in DIFFERENT slots still must not overlap on one track.",
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
            name: .applyTransition,
            description: "Applies a first-class transition between two adjacent clips on the same track, as one undoable action. Dissolve, slide and push render their overlap through an upper-track copy of the incoming clip; dip-to-black needs no overlap and is expressed as opacity keyframes. The incoming clip needs enough unused source before its start to cover half the duration. Audio crossfades as matched fades on the linked clips, not equal-power. Deleting a clip in a transition removes the transition and its overlays with it.",
            inputSchema: objectSchema(
                properties: [
                    "outgoingClipId": ["type": "string", "description": "Clip that plays first; the transition is centered on its end frame."],
                    "incomingClipId": ["type": "string", "description": "Clip that plays second; must start exactly where the outgoing clip ends."],
                    "type": ["type": "string", "enum": ["dissolve", "dipToBlack", "slide", "push"], "description": "Transition style."],
                    "direction": ["type": "string", "enum": ["left", "right", "up", "down"], "description": "Required for slide and push: the direction of motion. Forbidden otherwise."],
                    "durationFrames": ["type": "integer", "description": "Total transition length in frames, at least 2, fitting inside both clips."],
                ],
                required: ["outgoingClipId", "incomingClipId", "type", "durationFrames"]
            )
        ),
        AgentTool(
            name: .removeTransition,
            description: "Removes a transition by id: deletes its overlay clips, clears the keyframes it wrote, restores the previous audio fades, and drops the record. One undo step. Works on stale transitions too.",
            inputSchema: objectSchema(
                properties: [
                    "transitionId": ["type": "string", "description": "Transition id from an apply_transition receipt or get_timeline."],
                ],
                required: ["transitionId"]
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
                    "searchWindowSeconds": ["type": "number", "description": "Optional max ± offset to search in seconds. Omit to search the full feasible overlap."],
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
                                "layout": [
                                    "type": "string",
                                    "enum": VideoLayout.allCases.filter { $0 != .full }.map(\.rawValue),
                                    "description": "Multi-angle layout. Grid cells are rNcN counting from the top-left (r1c1 is top-left, row 1 is the top row); shaped layouts name slots by role.",
                                ],
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
            description: "Reverts the latest action from the editor's shared undo history, whether the user or agent made it. Call only when that latest action should be reversed. For example, verify a cut with get_transcript, then undo if it overshot and retry with corrected ranges. After undoing, ids and frames returned by the reverted action may be invalid; re-read with get_timeline or get_transcript before editing again. Takes no arguments.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .getTranscript,
            description: "Returns the spoken transcript of the CURRENT timeline in project frames — the post-edit caption track in one call. Unlike inspect_media (which transcribes one source asset in isolation, in source seconds), this walks every audio/video clip on the timeline, maps each word through that clip's trim/speed/position, and concatenates in timeline order. Deleted ranges are gone by construction, so after cuts this always reflects what's actually audible — no stale results, no per-clip frame math. Pass trackIndex to isolate one dialogue or multicam mic track; omit it to read every eligible timeline source (multicam defaults to its master mic). The app chooses cloud only when the signed-in account has enough credits for the uncached request; otherwise it uses local transcription and reports the resolved transcriptionSource in the response.\n\nReturns clips in timeline order, each with its words as compact [index, text, startFrame] rows (a word runs to the next word's start; the last word to its clip's end). Speakers, when identified, arrive as run-length turns: speakers = [[firstWordIndex, name], ...]. The index is a stable, 0-based position in the requested transcript; pass it straight to remove_words to cut that word (the intuitive path for text-based editing). Indices stay stable when paged with a window. Capped at 10000 words; page with startFrame/endFrame using nextStartFrame.\n\nFor comprehension rather than cutting — summarizing, finding a topic, take selection on long media — pass granularity='segments': sentence rows [firstWordIndex, text, start, end] at a fraction of the tokens, whose firstWordIndex jumps you back into word mode for the cut window.\n\nUse for transcript-driven edits (filler-word / dead-air removal, locating a quote, take selection) and to verify what remains after cutting. To cut, prefer remove_words (give it the indices); drop to ripple_delete_ranges only for non-word-aligned spans.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Only return words ending after this project frame. Use with the returned nextStartFrame to page a long timeline."],
                    "endFrame": ["type": "integer", "description": "Optional. Only return words starting before this project frame."],
                    "clipId": ["type": "string", "description": "Scope the transcript to a single clip — returns only what that clip says, in project frames. Answers \"what's in clip X?\" without scanning the whole timeline."],
                    "trackIndex": ["type": "integer", "description": "Scope transcription to one current timeline track from get_timeline. Use this to choose a dialogue or multicam mic lane. Mutually exclusive with clipId."],
                    "granularity": ["type": "string", "enum": ["words", "segments"], "description": "words (default) for cutting with remove_words; segments for cheap sentence-level reading — rows carry firstWordIndex to drill back into words."],
                    "language": ["type": "string", "description": "Optional BCP-47 speech language. Applies to local only; cloud auto-detects."],
                ]
            )
        ),
        AgentTool(
            name: .removeWords,
            description: "Cut speech by the word, Descript-style — the primary tool for text-based editing (filler words, flubbed sentences, dropped retakes, tightening a ramble). Pass words for precise get_transcript indices/ranges, or matches for exact filler tokens like \"um\" and \"uh\". This resolves them to frames, removes the surrounding pause so survivors don't end up double-spaced, merges adjacent removals, cuts linked A/V partners, and closes the gaps. You never deal in frame numbers — that's the whole point versus ripple_delete_ranges.\n\nWorkflow: call get_transcript, read it as prose, then pass the indices of the words to drop. Omit language by default; remove_words reuses the previous get_transcript provider and track selection so word indices stay aligned. Words across multiple clips on ONE track are handled in a single undoable action, and any linked A/V partner (e.g. the video paired with this audio) is cut automatically. Edit one track at a time: if your indices span multiple unlinked tracks (e.g. two separate mics), the call is refused — cut each track in its own call, or link the tracks into one unit first. After it runs, indices have shifted — re-read get_transcript before another remove_words.\n\nWhen to use which: words for selective edits after reading the transcript; matches for removing every exact filler token; ripple_delete_ranges only for spans that aren't word-aligned. Verify reworded retakes and sub-frame seam fragments against the word list, not a summary.",
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
            description: "Remove dead air — quiet, speech-free sections — from the timeline's audio, ripple-closing the gaps. Sections come from on-device speech detection (the same spans marked red on waveforms): non-speech runs whose level sits well below the recording's own speech level, so music beds and loud ambience are never cut. Cuts linked A/V partners and honors sync lock; the whole pass is one undoable action.\n\nOmit clipIds to process the whole timeline, or pass clip IDs from get_timeline to process only those clips. A scoped selection must include audio from exactly one track, and all selected clips must share one track or belong to one linked A/V unit. By default, this uses the current Minimum Pause and Speech Padding controls. Pass either optional value as a one-shot override without changing those controls. Use this to tighten pacing (long pauses, dead space between takes) before or instead of word-level edits: remove_silence handles pauses, remove_words handles fillers and flubbed lines. No transcript needed. If it reports no dead air, speech analysis may still be running in the background — wait a moment and retry.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "minItems": 1,
                        "description": "Optional timeline clip IDs from get_timeline. Restricts removal to these clips; linked A/V partners are cut with them. Include audio clips from exactly one track, and select clips from one track or one link group. Omit to process the whole timeline.",
                    ],
                    "minimumPauseSeconds": [
                        "type": "number",
                        "minimum": SilenceRemovalSettings.minimumPauseRange.lowerBound,
                        "maximum": SilenceRemovalSettings.minimumPauseRange.upperBound,
                        "description": "Minimum quiet, speech-free pause to remove. Omit to use the current Minimum Pause control.",
                    ],
                    "speechPaddingSeconds": [
                        "type": "number",
                        "minimum": SilenceRemovalSettings.speechPaddingRange.lowerBound,
                        "maximum": SilenceRemovalSettings.speechPaddingRange.upperBound,
                        "description": "Audio to keep before and after detected speech. Omit to use the current Speech Padding control.",
                    ],
                ],
                required: []
            )
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
            description: "Adds text clips as timeline layers. Omit trackIndex on every entry to create one new top video track; otherwise set trackIndex on every entry. Text boxes auto-fit their content; transform optionally sets their alignment-relative horizontal anchor, vertical center, Z rotation, and static X/Y perspective tilt. Left-aligned text grows rightward from x, centered text grows around x, and right-aligned text grows leftward from x. Use style widthScale and heightScale to stretch glyphs. Use the nested style object for typography, outline, shadow, background, and whole-layer Gaussian blur. fillMode 'footage' stencils layers below through the letter shapes over a matte set by style.color; it defaults to black when color is omitted. 'inverted' renders white glyphs with Difference blending and ignores color, outline, shadow, and background while active. Use add_captions for spoken audio captions. Unknown fields are rejected.",
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
                                    "description": "Optional position and rotation. Omitted x or y uses the default centered position. Size always auto-fits the text.",
                                    "properties": textTransformProperties(),
                                ],
                            ], textStyleProperties(detailed: false), [
                                "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Animation preset; off clears."],
                                "highlightColor": ["type": "string", "description": "Active-word hex."],
                                "fillMode": ["type": "string", "enum": TextFillMode.allCases.map(\.rawValue), "description": "color = solid typography (default). footage = stencil layers below through the letter shapes over a matte set by style.color, defaulting to black when color is omitted. inverted = white Difference-blended glyphs; color, outline, shadow, and background are ignored while active."],
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
            description: "Updates text clips or a captionGroupId. The nested style object is a partial patch: omitted values stay unchanged. Use it for typography, color, outline, shadow, background, and whole-layer Gaussian blur. style.blur is measured in 1080p canvas pixels, scales with output resolution, and 0 removes it; setting it clears blur keyframes. Use style widthScale and heightScale to stretch glyphs. fillMode 'footage' stencils layers below through the glyphs over a matte set by style.color; entering it defaults to black when color is omitted. 'inverted' renders white glyphs with Difference blending and ignores color, outline, shadow, and background while active. Content and layout-affecting style changes auto-fit the box while preserving its alignment-relative x anchor. transform can reposition, rotate, or apply static X/Y perspective tilt without changing its size. Static Z rotation uses clockwise degrees and clears rotation keyframes. Unknown fields are rejected.",
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
                        "description": "Partial position and rotation; omitted fields keep current values. Size remains auto-fit.",
                        "properties": textTransformProperties(),
                    ],
                ], textStyleProperties(detailed: true), [
                    "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Animation preset; off clears."],
                    "highlightColor": ["type": "string", "description": "Active-word hex."],
                    "fillMode": ["type": "string", "enum": TextFillMode.allCases.map(\.rawValue), "description": "color = solid typography. footage = stencil layers below through the letter shapes over a matte set by style.color, defaulting to black when entering without color. inverted = white Difference-blended glyphs; color, outline, shadow, and background are ignored while active."],
                ]),
                required: []
            )
        ),
        AgentTool(
            name: .addCaptions,
            description: "Transcribes spoken audio and creates caption text clips on their own track. Style, animation, and transform are optional overrides: omit them ALL for the app's clean default captions (plain white Helvetica, lower-third) — do not invent fonts, colors, outlines, backgrounds, blur, or animations the user didn't ask for. style.blur adds whole-layer Gaussian blur. Pass trackIndex to caption one dialogue or multicam mic track; omit it to automatically choose the timeline track with the most speech. The app uses cloud only when the signed-in account has enough credits for the uncached request; otherwise it uses local transcription. Cloud auto-detects language. Per-word animations are timed from the transcript. Alternatively, pass subtitleMediaRef (a subtitle asset from import_media/get_media) to place that SRT/WebVTT file's cues as captions at their authored timecodes — no transcription; the file's text, timing, and default styling are used as-is (overlapping cues are trimmed so clips never overlap on the track), so subtitleMediaRef can't be combined with any other parameter. Returns the caption group summary (captionGroupId, clipCount, frameRange, shared style, textPreview) — restyle it later with update_text and that captionGroupId.",
            inputSchema: objectSchema(
                properties: mergedProperties([
                    "subtitleMediaRef": ["type": "string", "description": "Subtitle asset id (type 'subtitle'). Places the file's cues at their timecodes instead of transcribing. Mutually exclusive with every other parameter except platform, which is allowed because a subtitle file specifies no position of its own — the text and timing come from the file untouched while."],
                    "language": ["type": "string", "description": "BCP-47 speech language. Applies to local only; cloud auto-detects."],
                    "trackIndex": ["type": "integer", "description": "Caption one current timeline track from get_timeline. Omit to auto-detect the dominant speech track."],
                    "transform": [
                        "type": "object",
                        "description": "Caption position and rotation; size is auto-fit per caption. x uses the selected text alignment edge.",
                        "properties": textTransformProperties(),
                    ],
                    "censorProfanity": ["type": "boolean", "description": "Mask profanity."],
                    "maxWords": ["type": "integer", "minimum": 1, "description": "Max words per caption."],
                    "maxCharacters": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "Max characters per caption, including spaces and punctuation. A single word may exceed this limit.",
                    ],
                    "maximumGapSeconds": [
                        "type": "number",
                        "minimum": CaptionGapSettings.maximumGapRange.lowerBound,
                        "maximum": CaptionGapSettings.maximumGapRange.upperBound,
                        "description": "Extend captions to close shorter gaps and hold the final caption for up to this duration. Default 0.5 seconds; 0 disables.",
                    ],
                ], textStyleProperties(detailed: false), [
                    "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Caption animation preset. Omit for static captions; set only when the user asks for animation."],
                    "highlightColor": ["type": "string", "description": "Active-word hex."],
                    "platform": ["type": "string", "enum": ["generic", "youtube", "tiktokShorts", "instagramReels"], "description": "Where the video is going. The platform's own interface covers part of the picture, so captions are narrowed and lifted clear of it — tiktokShorts and instagramReels keep the bottom fifth free, where their caption and button stacks sit. Defaults to generic, which keeps captions where they always were. Explicit transform values are still honoured, but are clamped clear of the interface."],
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
            order regardless of the order you pass them. Setting blur.gaussian.radius clears blur keyframes. \
            Undoable. Returns the clips with their resulting \
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
            name: .debreatheAudio,
            description: "Lower the volume of detected breath sounds in audio clips. Detection is spectral (low-band energy with a quiet consonant band), runs in the background, and the preview updates automatically when it finishes. strength scales the attenuation 0-1 (0 = untouched, 1 = breaths lowered by 24 dB); default 0.8. Pass enabled:false to turn it off. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Audio clip ids from get_timeline."],
                    "strength": ["type": "number", "description": "Attenuation scale, 0–1 (default 0.8)."],
                    "enabled": ["type": "boolean", "description": "Default true. false removes the de-breath effect from the clips."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .enhanceVoice,
            description: "One-click voice enhancement for audio clips: chains denoise, de-breath, de-esser, and loudness match (BS.1770-4) so clips sit at a common -16 LUFS. amount scales the whole chain 0-1 (default 0.7); deess scales only the sibilance stage 0-1 (default 0.6). Denoise bakes and detection run in the background — the timeline updates automatically when each stage finishes. Replaces any standalone denoise or de-breath effects on the clips. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Audio clip ids from get_timeline."],
                    "amount": ["type": "number", "description": "Chain strength, 0–1 (default 0.7)."],
                    "deess": ["type": "number", "description": "De-esser stage strength, 0–1 (default 0.6)."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .matchLoudness,
            description: "Measure each audio clip's integrated loudness (BS.1770-4, K-weighted, gated) and apply a volume offset that lands it on targetLUFS, so all selected clips sit at the same perceived level. Measurement runs in the background and is cached per source file. Typical voice target is -16 LUFS. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Audio clip ids from get_timeline."],
                    "targetLUFS": ["type": "number", "description": "Target integrated loudness, -30…14 (default -16)."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .generateDrone,
            description: "Render a tanpura/shruti-style tonal drone locally on this Mac (Karplus-Strong plucked-string synthesis — no server, no sign-in, no credits) and place it on its own audio track. Use to lay a drone bed under a vocal: set tonic to the vocal's key, scale to the maqam flavor (rast/hijaz/bayati/major/minor/sustain), pattern to the playing style (tanpura = Pa-Sa-Sa-Sa cycle, shrut = slow Sa+Pa sustain, sustain = single long ring). Pass placeUnder with an audio clipId to span that clip's full length; otherwise the drone starts at the playhead. levelDB sets the clip volume (default -18 dB, roughly 18-24 dB under a typical vocal). Returns the new clip and track ids.",
            inputSchema: objectSchema(
                properties: [
                    "tonic": ["type": "string", "description": "Drone key as a note name, e.g. \"C\", \"C#\", \"Eb\", \"A\"."],
                    "octave": ["type": "integer", "description": "Tonic octave 1-5 (default 3)."],
                    "scale": ["type": "string", "enum": DroneSynthesizer.Scale.allCases.map(\.rawValue), "description": "Maqam flavor: which note the dominant sits on (default rast)."],
                    "pattern": ["type": "string", "enum": DroneSynthesizer.Pattern.allCases.map(\.rawValue), "description": "Playing style (default tanpura)."],
                    "duration": ["type": "number", "description": "Length in seconds, 1-120 (default 30). Ignored when placeUnder is given."],
                    "placeUnder": ["type": "string", "description": "Audio clip id to span with the drone bed."],
                    "levelDB": ["type": "number", "description": "Clip volume in dB, -40…0 (default -18)."],
                ],
                required: ["tonic"]
            )
        ),
        AgentTool(
            name: .listSpeechVoices,
            description: "Lists the speech voices installed on this Mac, for use with generate_speech. Which voices exist varies per machine and per language, so call this before choosing a voice rather than guessing a name — an unknown name is refused. Filter by language to narrow the list (e.g. 'en-GB', 'hi-IN', 'ja-JP'); omit it for every installed voice. Returns name, identifier, language, gender, and whether the voice is an enhanced (downloaded) one, plus the full list of installed languages. Free and offline.",
            inputSchema: objectSchema(
                properties: [
                    "language": ["type": "string", "description": "Optional BCP-47 tag. Matches that language and its base language, so 'en' reaches en-GB, en-US and en-AU."],
                    "limit": ["type": "integer", "description": "Maximum voices to return, 1–200 (default 50)."],
                ]
            )
        ),
        AgentTool(
            name: .generateSpeech,
            description: "Speaks text — or a clip's own transcript — with a local voice, adds it to the media library, and optionally places it on the timeline. Free and offline: no server, no sign-in, no credits, and unlike generate_audio it never spends anything.\n\nTwo engines. Piper is a local neural synthesizer and is much more natural than the macOS system voices; it is used automatically whenever a Piper voice is installed for the language, and the receipt reports which engine actually rendered. The system voices are always available as a fallback and cover every language macOS ships, including ones Piper has no model for. Check the returned engine before promising a particular quality.\n\nUse it to voice a narration, to read a script, or to turn existing dialogue into a new take. Omit text and pass clipId (or trackIndex) to speak that audio's transcript — the words come from the same transcript get_transcript and add_captions use, so a spoken take and its captions cannot disagree. startFrame/endFrame narrow which part of the transcript to read.\n\nvoice takes a name or identifier from list_speech_voices — which voices exist varies per Mac, so never guess one; omit it to use the best voice for language. language is a BCP-47 tag and picks the voice when voice is omitted — use it when the words are not in the system language. rate and pitch are multipliers (1.0 = normal). Pass placeAtFrame to also drop the clip on a new audio track at that frame; otherwise the audio only joins the media library.\n\nNot every language has an installed voice — notably Malayalam has none on macOS, so Malayalam text is read badly. Check the voice's language in the result before promising a language match.",
            inputSchema: objectSchema(
                properties: [
                    "text": ["type": "string", "description": "Words to speak. Omit to speak a clip's transcript instead. Max \(SpeechSynthesizer.maxCharacters) characters."],
                    "clipId": ["type": "string", "description": "Speak this clip's transcript. Mutually exclusive with trackIndex."],
                    "trackIndex": ["type": "integer", "description": "Speak every audio clip on this track. Mutually exclusive with clipId."],
                    "startFrame": ["type": "integer", "description": "Only read transcript words overlapping this timeline frame or later."],
                    "endFrame": ["type": "integer", "description": "Only read transcript words overlapping this timeline frame or earlier. 0 or omitted means to the end."],
                    "voice": ["type": "string", "description": "Name or identifier from list_speech_voices. Omit to choose by language."],
                    "language": ["type": "string", "description": "BCP-47 tag used to pick a voice, e.g. 'en-GB', 'hi-IN', 'ja-JP'."],
                    "rate": ["type": "number", "description": "Speaking rate multiplier, 0.5–2.0 (default 1.0)."],
                    "pitch": ["type": "number", "description": "Pitch multiplier, 0.5–2.0 (default 1.0). Ignored by Piper, whose pitch is fixed by the voice."],
                    "engine": ["type": "string", "enum": ["piper", "system"], "description": "Which synthesizer to use. Omit to pick automatically: Piper when a voice is installed for the language, otherwise the macOS system voice. Pass system for the older, more robotic delivery, or piper to insist on the neural engine and fail loudly if its voice is missing rather than quietly substituting."],
                    "placeAtFrame": ["type": "integer", "description": "Also place the clip on a new audio track at this frame. Omit for library only."],
                    "trackName": ["type": "string", "description": "Name for the new audio track (default Voiceover)."],
                ]
            )
        ),
        AgentTool(
            name: .findStockMedia,
            description: "Searches free, openly-licensed sources for media to fill a gap in the cut — Creative Commons stills and sound effects with no setup at all, plus Pixabay stock video and Pexels stock photography and video once free API keys are added in Settings. Costs nothing and needs no account with Palmier.\n\nThis only searches; it never downloads. Each hit comes back with a direct `url` you pass to import_media (source.url), then place with add_clips. Use it when the library has no coverage of what the edit needs — search_media only finds what is already imported.\n\nEvery hit carries `license`, `licenseUrl`, `creator`, and a ready-made `attribution` line. Non-commercial and no-derivative results are filtered out, but attribution is still usually required, so read the license before publishing.\n\nVideo needs a configured keyed source; 'providers' reports per-source status, including which source was skipped and why. Phrase the query as a subject ('rain on a window at night'), not a style.",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "What to look for, as a plain subject description."],
                    "kind": ["type": "string", "enum": StockMediaKind.allCases.map(\.rawValue), "description": "What to search for (default image)."],
                    "orientation": ["type": "string", "enum": ["landscape", "portrait", "square"], "description": "Pexels only; defaults to landscape. Openverse and Pixabay ignore it."],
                    "maxDurationSeconds": ["type": "integer", "description": "Skip stock videos longer than this. Ignored for images and audio."],
                    "limit": ["type": "integer", "description": "Hits to return, 1–20 (default 8)."],
                ],
                required: ["query"]
            )
        ),
        AgentTool(
            name: .findShotCandidates,
            description: "Find footage worth cutting by combining ready library evidence with downloadable stock catalog rows. Returns a deterministic shortlist with one candidate per known source identity, not one per trim. Ranks usable local matches first and reports skipped rows with reasons. Pass excludedSourceIds to request distinct alternatives; planId also excludes the plan's selected mediaRef sources by default. Manifest-wide aliases connect media refs, valid content hashes, and retained stock origins across local and remote results. Unknown identities remain unresolved blockers, never wildcard exclusions; search does not verify identity freshness or perceptual similarity. Returns evidence, source spans and durations where known, cached library or provider dimensions where available, and remote license, attribution, thumbnailUrl and landingPageUrl where supplied. Unknown metadata is omitted, not measured during search. Catalog matches and thumbnails do not verify visual content: use inspect_media after import to inspect the actual source. It never changes plans, selections, approvals, or undo, and never downloads, imports, or places media: import a remote url with import_media, then place mediaRef with add_clips. Requesting alternatives does not authorize automatic plan retargeting. Query visual captions or exact spoken words; kind is required because visual and spoken evidence differ.",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "Subject caption for visual search or exact words for spoken matching."],
                    "kind": ["type": "string", "enum": StockMediaKind.allCases.map(\.rawValue), "description": "Required media kind."],
                    "scope": ["type": "string", "enum": ["visual", "spoken", "both"], "description": "Library evidence to use. Images need visual; audio needs spoken."],
                    "mediaRef": ["type": "string", "description": "Optional. Restrict library matches to one asset. Remote stock is unrestricted."],
                    "excludedSourceIds": ["type": "array", "items": ["type": "string", "minLength": 1, "maxLength": VisualSourceAliases.maximumSourceIdLength], "maxItems": ShotCandidateExclusions.maximumExplicitSourceIds, "uniqueItems": true, "description": "Optional canonical exclusion set: media:<mediaRef>, sha256:<64 lowercase hex digits>, or stock:<provider>:<assetId>. At most 256 distinct IDs. Excludes all known manifest aliases before shortlist limits; URLs and candidate span IDs are not identities."],
                    "planId": ["type": "string", "minLength": 1, "maxLength": VisualSourceAliases.maximumEntityIdLength, "description": "Optional existing plan ID. Its selected mediaRef sources and all known aliases are excluded in addition to excludedSourceIds. Does not change the plan or its approval."],
                    "includeLibrary": ["type": "boolean", "description": "Include imported media (default true)."],
                    "includeRemote": ["type": "boolean", "description": "Include downloadable stock (default true)."],
                    "orientation": ["type": "string", "enum": ["landscape", "portrait", "square"], "description": "Optional remote image or video aspect ratio. Excludes hits without matching known dimensions. Not valid for audio."],
                    "maxDurationSeconds": ["type": "integer", "minimum": 1, "description": "Maximum remote video or audio duration. Excludes hits without a known duration. Not valid for images."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 20, "description": "Distinct usable source candidates to return, 1–20 (default 8)."],
                ],
                required: ["query", "kind"]
            )
        ),
        AgentTool(
            name: .listModels,
            description: "Lists hosted AI models with their durations, aspect ratios, resolutions, references, audio inputs/voices, and upscale settings. Call before generate_video, generate_image, generate_audio, or upscale_media. Returns {models, loaded, availability}. availability is the same current prerequisite decision used by execution and UI; when blocked, use its reason rather than assuming signing in will help. hosted_build_excluded cannot be resolved with an account or credits. loaded=false means catalog metadata is not ready, not that the catalog has no models. Local speech, drones, and stock providers are described by get_capabilities.",
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
                    "prompt": ["type": "string", "description": "Text description of the video to generate. Optional for transforms such as lip sync that do not use a prompt."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'veo3.1-fast'). Use list_models to see options. Defaults to first available model."],
                    "duration": ["type": "integer", "description": "Duration in seconds. Valid values depend on model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16', '1:1')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '720p', '1080p', '4k')"],
                    "draft": ["type": "boolean", "description": "Generate a lower-cost 720p preview when list_models reports supportsDraft=true. The resulting media can be enhanced later without changing its motion."],
                    "enhanceDraftMediaRef": ["type": "string", "description": "Completed draft asset ID to render at full quality without changing its motion. Use alone instead of prompt/model/input parameters."],
                    "startFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the first frame (image-to-video)"],
                    "endFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the last frame (supported by some models)"],
                    "sourceVideoMediaRef": ["type": "string", "description": "Media asset ID of a source video required by video-to-video models. Pass duration when the selected model lists output durations; otherwise the source duration determines billing."],
                    "sourceClipId": ["type": "string", "description": "Optional. Clip id (from get_timeline) referencing sourceVideoMediaRef. When set and the clip is trimmed, only the clip's visible range is sent to the model, not the full source — matches the UI's 'Use trimmed portion only'."],
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of image references. Covers both reference-to-video generation (Seedance, Kling V3/O3 elements, Grok — refer as @Image1/@Element1 in prompt) and the single-image ref used by video-to-video edit models (Kling V3 Motion Control). See list_models maxReferenceImages for per-model cap."],
                    "referenceVideoMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of video references (Seedance only). Refer to them as @Video1, @Video2. See maxReferenceVideos and maxCombinedVideoRefSeconds."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of audio references. Lip-sync models use this as the replacement audio track; prompt-driven models refer to them as @Audio1, @Audio2. See maxReferenceAudios, requiresReferenceAudio, and maxCombinedAudioRefSeconds."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
                ]
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
            description: "Starts an async AI audio generation or transformation. Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS converts text into speech. Generative audio models create dialogue, music, or sound effects from a prompt, video, or supported image/audio references. Voice Cleanup isolates speech from background audio. Dubbing translates source speech while preserving speaker delivery; pass targetLanguage. For models whose inputs include audio or video, provide sourceMediaRef. Video-to-audio scoring models also accept videoSourceStartFrame+videoSourceEndFrame and place the result on the timeline automatically. Other results land in the media library for placement with add_clips. Use list_models with type='audio' to inspect inputs, category, voices, reference caps, and limits. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Required for text-driven models. TTS uses it as spoken text; generative audio models use it as the scene, music, or sound description. Omit for Voice Cleanup and Dubbing."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID. Use list_models with type='audio' to see options and their 'inputs'. Defaults to the first model."],
                    "voice": ["type": "string", "description": "TTS only. Voice preset name. list_models shows voicesSample (first 3) + voiceCount; any voice supported by the model is accepted. Defaults to the model's defaultVoice. Ignored by music models."],
                    "lyrics": ["type": "string", "description": "MiniMax Music only. Lyrics with optional [Verse]/[Chorus] section tags. If omitted and instrumental=false, MiniMax auto-writes lyrics from the prompt."],
                    "styleInstructions": ["type": "string", "description": "Gemini TTS only. Optional delivery instructions (e.g. 'warm and slow', 'British accent')."],
                    "instrumental": ["type": "boolean", "description": "Music models only. true = no vocals when the selected model supports it. Defaults to false."],
                    "duration": ["type": "integer", "description": "Length in seconds. ElevenLabs Music: 3–600. Sonilo text-to-music: up to 600. Video-to-audio models default to the source span; pass a value to request a different output length. Voice Cleanup and Dubbing always preserve the source length. Ignored by TTS, MiniMax, and Lyria 3 Pro."],
                    "sourceMediaRef": ["type": "string", "description": "Source audio or video asset ID for models whose inputs include audio or video. Required for Voice Cleanup and Dubbing."],
                    "targetLanguage": ["type": "string", "description": "Required for Dubbing. ISO language code such as 'es', 'fr', 'de', or 'ja'."],
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Image asset IDs for audio models that support image references. See list_models for the count limit. Mutually exclusive with referenceAudioMediaRefs when list_models reports referenceImagesAndAudiosExclusive."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Audio asset IDs for audio models that support audio references. Refer to them in the prompt as @Audio1, @Audio2, and @Audio3. See list_models for the count, duration, and file-type limits."],
                    "multilingual": ["type": "boolean", "description": "Enable multilingual generation when supported by the selected model. Defaults to false."],
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
            description: "Enhances an existing video or image with an AI upscaler. It can change resolution, interpolate video frame rate, or apply model-specific restoration settings. Returns a placeholder asset ID immediately; the result appears in get_media once ready. Call list_models with type='upscale' first and use its exact setting IDs and values. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the video or image asset to upscale"],
                    "model": ["type": "string", "description": "Upscaler model ID (e.g. 'bytedance-upscaler', 'seedvr-image-upscaler'). Defaults to the first model that supports the asset's type."],
                    "sourceClipId": ["type": "string", "description": "Optional. Video clip id (from get_timeline) referencing mediaRef. When set and the clip is trimmed, only the clip's visible range is upscaled, not the full source."],
                    "settings": [
                        "type": "object",
                        "description": "Optional flat map of setting ID to value from list_models. Select settings take strings, numeric settings take numbers, and toggle settings take booleans. Omitted settings use model defaults. Example: {\"targetResolution\":\"4k\",\"targetFPS\":\"60\",\"enhancementModel\":\"Proteus\",\"noise\":0.2}.",
                    ],
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

    /// In-app assistant only
    static let manageSkills = AgentTool(
        name: .manageSkills,
        description: "Create, update, or permanently remove reusable skills for the in-app assistant. Set `action` to: `create` with name, description, and complete Markdown instructions; `update` with an exact skill id and at least one field to replace; or `remove` with an exact skill id. Updates are partial patches, but `instructions`, when present, replaces the complete Markdown body, so call read_skill first when preserving existing instructions. Use remove only when the user explicitly asks to delete that skill. The app generates and returns a stable id for created skills.",
        inputSchema: objectSchema(
            properties: [
                "action": [
                    "type": "string",
                    "enum": ["create", "update", "remove"],
                    "description": "Skill operation.",
                ],
                "id": [
                    "type": "string",
                    "description": "Update/remove only. Exact skill id listed under # Skills.",
                ],
                "name": [
                    "type": "string",
                    "maxLength": Skill.Limits.maximumNameLength,
                    "description": "Create/update. Concise skill display name on one line.",
                ],
                "description": [
                    "type": "string",
                    "maxLength": Skill.Limits.maximumDescriptionLength,
                    "description": "Create/update. One-line trigger description explaining when the assistant should use the skill.",
                ],
                "instructions": [
                    "type": "string",
                    "maxLength": Skill.Limits.maximumInstructionsLength,
                    "description": "Create/update. Complete replacement Markdown instructions without YAML frontmatter.",
                ],
            ],
            required: ["action"]
        )
    )

    /// MCP server only
    static let manageProject = AgentTool(
        name: .manageProject,
        description: "List, open, create, or close Palmier projects for this MCP session. Set `action` to: `list` for known projects plus session-active and visible state; `open` with a name, id from list, or .palmier path; `create` with an optional name and initial fps/aspectRatio/quality; or `close` to save and close the session project, optionally targeting another open project by name/id/path. Opening or creating changes only this session's target. Closing always completes a final save first. This tool never deletes projects or files.",
        inputSchema: objectSchema(
            properties: [
                "action": ["type": "string", "enum": ["list", "open", "create", "close"], "description": "Project operation."],
                "name": ["type": "string", "description": "Project name. For open/close, matched case-insensitively; for create, defaults to 'Untitled Project'."],
                "id": ["type": "string", "description": "Project id returned by action='list'. Used by open or close."],
                "path": ["type": "string", "description": "Filesystem path to a .palmier package. Used by open or close."],
                "fps": ["type": "integer", "description": "Create only. Optional timeline frame rate (1-120)."],
                "aspectRatio": [
                    "type": "string",
                    "description": "Create only. Optional canvas aspect ratio as width:height, such as '16:9', '3:2', or '2.39:1'.",
                ],
                "quality": [
                    "type": "string",
                    "enum": ["720p", "1080p", "2K", "4K"],
                    "description": "Create only. Optional resolution preset applied to the aspect ratio.",
                ],
            ],
            required: ["action"]
        )
    )

    static var mcpServer: [AgentTool] { all + [manageProject] }
    static var inAppAgent: [AgentTool] { all + [readSkill, manageSkills] }

    private static func textTransformProperties() -> [String: [String: Any]] {
        [
            "x": ["type": "number", "description": "Normalized horizontal anchor of the unrotated text box: the left edge for left alignment, center for center alignment, or right edge for right alignment."],
            "y": ["type": "number", "description": "Normalized vertical center."],
            "rotation": ["type": "number", "description": "Clockwise Z-axis degrees."],
            "rotationX": ["type": "number", "minimum": Transform.tiltRotationRange.lowerBound, "maximum": Transform.tiltRotationRange.upperBound, "description": "Static X-axis perspective rotation in degrees. Positive tips the top edge away from the viewer."],
            "rotationY": ["type": "number", "minimum": Transform.tiltRotationRange.lowerBound, "maximum": Transform.tiltRotationRange.upperBound, "description": "Static Y-axis perspective rotation in degrees. Positive brings the right edge toward the viewer."],
        ]
    }

    private static func textStyleProperties(detailed: Bool) -> [String: [String: Any]] {
        let properties: [String: [String: Any]] = [
            "style": [
                "type": "object",
                "description": "Partial text-style patch. Omitted properties keep existing values (updates) or the app's default style (new text and captions). Set only what the user asked for; omit the whole object when they didn't specify a look.",
                "properties": [
                    "fontName": ["type": "string", "description": "Font PostScript name."],
                    "fontSize": ["type": "number", "minimum": 12, "maximum": 300, "description": "Font size in canvas points."],
                    "widthScale": ["type": "number", "minimum": TextStyle.axisScaleRange.lowerBound, "maximum": TextStyle.axisScaleRange.upperBound, "description": "Glyph width multiplier. 1 preserves the font's original width."],
                    "heightScale": ["type": "number", "minimum": TextStyle.axisScaleRange.lowerBound, "maximum": TextStyle.axisScaleRange.upperBound, "description": "Glyph height multiplier. 1 preserves the font's original height."],
                    "bold": ["type": "boolean", "description": "Bold font trait."],
                    "italic": ["type": "boolean", "description": "Italic font trait."],
                    "underline": ["type": "boolean", "description": "Draw a line below the text."],
                    "strikethrough": ["type": "boolean", "description": "Draw a line through the text."],
                    "overline": ["type": "boolean", "description": "Draw a line above the text."],
                    "tracking": ["type": "number", "minimum": -20, "maximum": 100, "description": "Spacing between characters in canvas points."],
                    "lineSpacing": ["type": "number", "minimum": -100, "maximum": 300, "description": "Additional spacing between lines in canvas points."],
                    "fontCase": ["type": "string", "enum": ["mixed", "uppercase", "lowercase"], "description": "Non-destructive display casing."],
                    "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text alignment."],
                    "color": ["type": "string", "description": "Text color as #RGB, #RRGGBB, or #RRGGBBAA."],
                    "blur": ["type": "number", "minimum": 0, "maximum": 100, "description": "Whole-layer Gaussian blur in 1080p canvas pixels. Blurs glyphs, outline, shadow, and background; 0 removes it."],
                    "outline": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "color": ["type": "string", "description": "Outline color hex."],
                            "width": ["type": "number", "minimum": 0, "maximum": 40, "description": "Width in canvas points."],
                        ],
                    ],
                    "shadow": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "color": ["type": "string", "description": "Shadow color hex. Six-digit colors preserve the current opacity."],
                            "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                            "offset": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number", "minimum": -200, "maximum": 200],
                                    "y": ["type": "number", "minimum": -200, "maximum": 200],
                                ],
                            ],
                            "blur": ["type": "number", "minimum": 0, "maximum": 100, "description": "Blur radius in canvas points."],
                        ],
                    ],
                    "background": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "color": ["type": "string", "description": "Background color hex. Six-digit colors preserve the current opacity."],
                            "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                            "padding": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number", "minimum": 0, "maximum": 300],
                                    "y": ["type": "number", "minimum": 0, "maximum": 300],
                                ],
                            ],
                            "center": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number", "minimum": -500, "maximum": 500],
                                    "y": ["type": "number", "minimum": -500, "maximum": 500],
                                ],
                            ],
                            "cornerRadius": ["type": "number", "minimum": 0, "maximum": 300, "description": "Corner radius in canvas points."],
                            "outline": [
                                "type": "object",
                                "properties": [
                                    "color": ["type": "string", "description": "Background outline color hex."],
                                    "width": ["type": "number", "minimum": 0, "maximum": 40, "description": "Background outline width in canvas points."],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        guard !detailed, var style = properties["style"] else { return properties }
        style = schemaWithoutDescriptions(style)
        style["description"] = "Same partial style patch as update_text. Omit entirely unless the user asked for specific styling; omitted = app default style."
        return ["style": style]
    }

    private static func schemaWithoutDescriptions(_ schema: [String: Any]) -> [String: Any] {
        schema.reduce(into: [:]) { result, entry in
            guard entry.key != "description" else { return }
            if let nested = entry.value as? [String: Any] {
                result[entry.key] = schemaWithoutDescriptions(nested)
            } else if let items = entry.value as? [Any] {
                result[entry.key] = items.map { item in
                    guard let nested = item as? [String: Any] else { return item }
                    return schemaWithoutDescriptions(nested)
                }
            } else {
                result[entry.key] = entry.value
            }
        }
    }

    private static func mergedProperties(_ chunks: [String: [String: Any]]...) -> [String: [String: Any]] {
        chunks.reduce(into: [:]) { merged, chunk in
            merged.merge(chunk) { _, new in new }
        }
    }

    private static var referenceRecipeSchema: [String: Any] {
        objectSchema(properties: [
            "title": ["type": "string", "description": "Reference title."],
            "sourceURL": ["type": "string", "description": "HTTPS reference URL; records provenance without fetching it."],
            "sourceDurationSeconds": ["type": "number", "description": "Optional finite positive reference runtime, never the requested output runtime."],
            "coverage": ["type": "array", "items": ["type": "string", "enum": ReferenceRecipe.Coverage.allCases.map(\.rawValue)], "description": "Unique inspection modes actually used."],
            "limitations": ["type": "string", "description": "Required truthful inspection limits, including unverified motion/audio."],
            "cues": ["type": "array", "minItems": 1, "maxItems": 128, "items": objectSchema(properties: [
                "cueId": ["type": "string", "description": "Stable cue ID, unique within the recipe."],
                "kind": ["type": "string", "enum": ReferenceRecipe.Cue.Kind.allCases.map(\.rawValue)],
                "evidence": ["type": "string", "enum": ReferenceRecipe.Cue.Evidence.allCases.map(\.rawValue)],
                "startSeconds": ["type": "number", "description": "Reference source time, paired with endSeconds; required for observed cues."],
                "endSeconds": ["type": "number", "description": "Exclusive source time, inside source duration when known."],
                "observation": ["type": "string", "description": "What was observed, inferred, or remains unverified."],
                "editorialRule": ["type": "string", "description": "Transferable explaining principle, not copied narration, assets, branding, or voice identity."],
            ], required: ["cueId", "kind", "evidence", "observation", "editorialRule"])],
        ], required: ["title", "sourceURL", "coverage", "cues", "limitations"])
    }

    private static var scriptBeatsSchema: [String: Any] {
        ["type": "array", "minItems": 1, "maxItems": 256, "description": "Ordered script paragraphs; at most 20,000 spoken characters total. Source-linked facts use claimIds. Updating text or pronunciation invalidates measured narration timing.",
         "items": objectSchema(properties: [
            "beatId": ["type": "string", "description": "Stable paragraph/beat ID, unique across plan elements."],
            "text": ["type": "string", "description": "Authored narration paragraph."],
            "spokenText": ["type": "string", "description": "Optional explicit pronunciation wording; this is what must be spoken and aligned, not text."],
            "purpose": ["type": "string", "description": "Editorial purpose of this beat."],
            "claimIds": claimIdsSchema,
         ], required: ["beatId", "text", "purpose"])]
    }

    private static var narrationIntentSchema: [String: Any] {
        var schema = objectSchema(properties: [
            "language": ["type": "string", "description": "Authored narration language/locale tag. Required for managed approval; local speech must match the exact installed voice language."],
            "startFrame": ["type": "integer", "minimum": 0, "maximum": maxFrameArg, "description": "Authored narration placement in project frames. Whole attached source at normal speed; no trims or speed changes."],
            "narrator": ["description": "Exact narrator intent. Recording identity and Piper model/config identities are measured by the app and returned in readback; never supply asserted hashes. Omit only for a generic draft, not managed approval. Resolving intent does not generate, install, download, or spend credits.",
                "oneOf": [recordingNarratorSchema, localSpeechNarratorSchema(engine: .system), localSpeechNarratorSchema(engine: .piper)]],
        ], required: ["startFrame"])
        schema["additionalProperties"] = false
        schema["allOf"] = [[
            "if": ["required": ["narrator"], "properties": ["narrator": ["required": ["kind"], "properties": ["kind": ["const": "local_speech"]]]]],
            "then": ["required": ["language"]],
        ]]
        return schema
    }

    private static var recordingNarratorSchema: [String: Any] {
        var schema = objectSchema(properties: [
            "kind": ["type": "string", "enum": ["recording"]],
            "mediaRef": ["type": "string", "description": "Explicitly chosen ready library audio asset. The app measures its actual bytes before committing intent; eventual narration attachment must match those bytes, including an explicitly selected identical-byte alias."],
        ], required: ["kind", "mediaRef"])
        schema["additionalProperties"] = false
        return schema
    }

    private static func localSpeechNarratorSchema(engine: LocalSpeechNarrator.Engine) -> [String: Any] {
        var schema = objectSchema(properties: [
            "kind": ["type": "string", "enum": ["local_speech"]],
            "engine": ["type": "string", "enum": [engine.rawValue], "description": "Exact installed local engine; no substitution or fallback."],
            "voiceIdentifier": ["type": "string", "description": "Exact installed system voice identifier or Piper model name from list_speech_voices. Names, prefixes, unknown voices, unavailable models, and language mismatches are refused; Piper model/config bytes are pinned by the app."],
            "rate": ["type": "number", "minimum": 0.5, "maximum": 2, "description": "Explicit finite rate multiplier, 1 = normal."],
            "pitch": ["type": "number", "minimum": engine == .piper ? 1 : 0.5, "maximum": engine == .piper ? 1 : 2, "description": "Explicit finite pitch multiplier. Piper requires 1; other pitch values are unsupported."],
        ], required: ["kind", "engine", "voiceIdentifier", "rate", "pitch"])
        schema["additionalProperties"] = false
        schema["description"] = "Available exact local speech intent may be approved without audio. Managed synthesized attachment proof is not implemented; generic speech receipts or package metadata never establish readiness."
        return schema
    }

    private static var narrationSourceSchema: [String: Any] {
        var schema = objectSchema(properties: [
            "mediaRef": ["type": "string", "description": "Ready library audio attachment. Language and placement belong to narrationIntent, not this source. Managed recordings must match the chosen byte identity; managed synthesized attachments remain blocked until pinned generation proof exists. Generic plans remain ordinary audio edits. Measurement never synthesizes or spends credits."],
        ], required: ["mediaRef"])
        schema["additionalProperties"] = false
        return schema
    }

    private static var sceneNarrationLinkSchema: [String: Any] {
        objectSchema(properties: [
            "firstBeatId": ["type": "string", "description": "First beat covered by this scene."],
            "lastBeatId": ["type": "string", "description": "Last beat covered, in script order."],
            "minimumHoldSeconds": ["type": "number", "minimum": 1, "maximum": 60, "description": "Minimum readable scene hold, defaults to 1 second. Shorter measured ranges block assembly; no silent stretch."],
        ], required: ["firstBeatId", "lastBeatId"])
    }

    private static var sourceLedgerSchema: [String: Any] {
        objectSchema(properties: [
            "sources": ["type": "array", "maxItems": SourceClaimLedger.maximumSources, "items": objectSchema(properties: [
                "sourceId": ["type": "string", "description": "Stable source ID, unique within this ledger."],
                "title": ["type": "string"],
                "url": ["type": "string", "description": "HTTPS evidence URL; mutually exclusive with documentReference. Not fetched by this tool."],
                "documentReference": ["type": "string", "description": "User-supplied document identifier or locator; mutually exclusive with url."],
                "author": ["type": "string", "description": "Source author/organization for factual attribution, not an asset license."],
                "publicationDate": ["type": "string", "description": "Optional YYYY-MM-DD; omit if unknown."],
                "accessedDate": ["type": "string", "description": "Required valid YYYY-MM-DD access date."],
            ], required: ["sourceId", "title", "author", "accessedDate"])],
            "claims": ["type": "array", "maxItems": SourceClaimLedger.maximumClaims, "items": objectSchema(properties: [
                "claimId": ["type": "string", "description": "Stable fact ID, unique within this ledger."],
                "kind": ["type": "string", "enum": SourceClaimLedger.Claim.Kind.allCases.map(\.rawValue)],
                "statement": ["type": "string", "description": "Exact factual assertion or identified location."],
                "value": ["type": "number", "description": "Finite numeric value; required only for quantity claims."],
                "unit": ["type": "string", "description": "Explicit unit for quantity claims; cannot be supplied for other kinds."],
                "status": ["type": "string", "enum": SourceClaimLedger.Claim.Status.allCases.map(\.rawValue), "description": "reviewed only for verified supplied evidence; changed reviewed facts/evidence become unresolved until explicitly reviewed again."],
                "evidence": ["type": "array", "maxItems": 16, "description": "Reviewed claims need at least one supporting passage. Unresolved claims may use an empty list to record missing evidence.", "items": objectSchema(properties: [
                    "sourceId": ["type": "string"],
                    "passage": ["type": "string", "description": "Exact supporting passage, not a lossy summary."],
                ], required: ["sourceId", "passage"])],
            ], required: ["claimId", "kind", "statement", "status", "evidence"])],
        ], required: ["sources", "claims"])
    }

    private static var claimIdsSchema: [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": "Unique factual claim IDs from this plan's sourceLedger. Referenced unresolved claims block apply_plan assembly."]
    }

    private static var referenceUseSchema: [String: Any] {
        objectSchema(properties: [
            "cueIds": ["type": "array", "items": ["type": "string"], "description": "Non-empty, unique IDs from this plan's referenceRecipe."],
            "rationale": ["type": "string", "description": "Why these reference principles suit this chapter or scene's argument."],
        ], required: ["cueIds", "rationale"])
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
