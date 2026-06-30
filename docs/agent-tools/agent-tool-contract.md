# Agent Tool Contract

This document is generated from `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift`.
Do not edit the tool list by hand. Run `swift scripts/sync-agent-tool-docs.swift --write` after changing agent tool definitions, and run `swift scripts/sync-agent-tool-docs.swift` before or after syncing upstream.

Tool count: 43 in-app agent tools, 42 MCP-exposed tools.

## Maintenance Contract

- `ToolDefinitions.swift` is the source of truth for names and descriptions.
- Any semantic change under `Sources/PalmierPro/Agent/Tools/` must update the corresponding tool description and regenerate this document.
- After syncing upstream, run `swift scripts/sync-agent-tool-docs.swift` to confirm the checked-in document still matches the current code.
- Install local hooks with `scripts/install-hooks.sh`; CI also runs the same check.

## Tool Index

1. `get_timeline` — In-app agent and MCP
2. `get_media` — In-app agent and MCP
3. `inspect_media` — In-app agent and MCP
4. `get_transcript` — In-app agent and MCP
5. `inspect_timeline` — In-app agent and MCP
6. `search_media` — In-app agent and MCP
7. `add_clips` — In-app agent and MCP
8. `insert_clips` — In-app agent and MCP
9. `remove_clips` — In-app agent and MCP
10. `remove_tracks` — In-app agent and MCP
11. `move_clips` — In-app agent and MCP
12. `apply_layout` — In-app agent and MCP
13. `set_clip_properties` — In-app agent and MCP
14. `set_keyframes` — In-app agent and MCP
15. `split_clips` — In-app agent and MCP
16. `ripple_delete_ranges` — In-app agent and MCP
17. `remove_words` — In-app agent and MCP
18. `sync_audio` — In-app agent and MCP
19. `undo` — In-app agent and MCP
20. `add_texts` — In-app agent and MCP
21. `update_text` — In-app agent and MCP
22. `add_captions` — In-app agent and MCP
23. `align_captions` — In-app agent and MCP when Volcengine Speech is configured
24. `export_project` — In-app agent and MCP
25. `generate_video` — In-app agent and MCP
26. `generate_image` — In-app agent and MCP
27. `generate_audio` — In-app agent and MCP
28. `upscale_media` — In-app agent and MCP
29. `import_media` — In-app agent and MCP
30. `list_folders` — In-app agent and MCP
31. `create_folder` — In-app agent and MCP
32. `move_to_folder` — In-app agent and MCP
33. `rename_media` — In-app agent and MCP
34. `rename_folder` — In-app agent and MCP
35. `delete_media` — In-app agent and MCP
36. `delete_folder` — In-app agent and MCP
37. `list_models` — In-app agent and MCP
38. `apply_effect` — In-app agent and MCP
39. `apply_color` — In-app agent and MCP
40. `inspect_color` — In-app agent and MCP
41. `set_project_settings` — In-app agent and MCP
42. `send_feedback` — In-app agent and MCP
43. `read_skill` — In-app agent only

## Tool Descriptions

### `get_timeline`

- Source case: `ToolName.getTimeline`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:58`
- Availability: In-app agent and MCP

Always call at the start of a session. Returns project settings (fps, resolution, totalFrames), track list with types and order, all clips with their frames and properties, and canGenerate. Generation/upscale tools may still fail if the selected provider or model endpoint is not configured; report that tool error directly. The clipId/trackId values here are what every other tool accepts.

Clip and track fields equal to their defaults are omitted: mediaType 'video', sourceClipType = mediaType, speed 1, volume 1, opacity 1, trims/fades 0, identity transform/crop, default textStyle, track muted/hidden false. Text clips never report trims (no source media).

Caption clips (sharing a captionGroupId) come back per track as captionGroups instead of clips entries: properties common to the group are hoisted into 'shared' and each clip is a [clipId, startFrame, durationFrames, text] row (caption box width/height are auto-fit per text and omitted). Rows are capped at 200 per group — when clipCount exceeds the rows shown, page with startFrame/endFrame. Caption clips whose properties deviate from the group appear individually in clips.

### `get_media`

- Source case: `ToolName.getMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:68`
- Availability: In-app agent and MCP

Call before referencing any asset. Every mediaRef/reference ID in other tools comes from the IDs returned here. Also exposes generationStatus (preparing | generating | downloading | failed | none) for async-generated and async-imported assets.

### `inspect_media`

- Source case: `ToolName.inspectMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:73`
- Availability: In-app agent and MCP

Look at a media asset before referencing or editing it. Images: the image plus dimensions and EXIF. Video: sample frames plus a transcription of the audio track. Audio: transcription. Lottie: frames sampled evenly across the animation (over gray), plus framerate and duration — use this to verify a Lottie you wrote looks and moves right. Transcription is sentence-level segments — [text, start, end] tuples, capped at 400 — in source seconds, or project frames when clipId is set. When capped, pass the returned nextStartSeconds as startSeconds for the next page.

Long media: pass overview=true for a one-image storyboard, read the segments, then re-call with startSeconds/endSeconds to zoom — windowed calls only transcribe that span, so they are fast.

### `get_transcript`

- Source case: `ToolName.getTranscript`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:90`
- Availability: In-app agent and MCP

Returns the spoken transcript of the CURRENT timeline in project frames — the post-edit caption track in one call. Unlike inspect_media (which transcribes one source asset in isolation, in source seconds), this walks every audio/video clip on the timeline, maps each word through that clip's trim/speed/position, and concatenates in timeline order. Deleted ranges are gone by construction, so after cuts this always reflects what's actually audible — no stale results, no per-clip frame math.

Returns clips in timeline order, each with its words nested as compact [index, text, startFrame, endFrame] rows (the field order is given once in wordFormat) — clipId and trackIndex are stated once per clip, not repeated per word. The index is a stable, global, 0-based position in timeline order; pass it straight to remove_words to cut that word (the intuitive path for text-based editing). Words are monotonic and non-overlapping; each is attributed to one clip, so a word split across a clip seam is emitted once. Indices stay global even when scoped with clipId or paged with a window. Capped at 10000 words total; page with startFrame/endFrame using nextStartFrame. Pass clipId to scope to a single clip ("what does this clip say?"). Transcription runs on-device.

Use for transcript-driven edits (filler-word / dead-air removal, locating a quote, take selection) and to verify what remains after cutting. To cut, prefer remove_words (give it the indices); drop to ripple_delete_ranges only for non-word-aligned spans.

### `inspect_timeline`

- Source case: `ToolName.inspectTimeline`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:102`
- Availability: In-app agent and MCP

See the composited timeline — what the user actually sees in the preview at a given frame: all video tracks stacked with their transforms, opacity, crop, and keyframes applied, plus text and caption overlays baked in. Use this to verify your edits landed (a PIP's position, a title's placement, layer order) — inspect_media shows the raw source asset, not the cut.

Frames are project frames (from get_timeline). Pass a single startFrame for one composited frame; add endFrame to sample maxFrames evenly across [startFrame, endFrame) for a transition or sequence. Frames past content render black. Returns frames downscaled for token efficiency, with the frameNumbers sampled.

### `search_media`

- Source case: `ToolName.searchMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:113`
- Availability: In-app agent and MCP

Search the media library by content: what's on screen (visual) and what's said (spoken). Visual matching is semantic and on-device — phrase the query like an image caption ('a wide shot of a harbor at sunset'), not keywords; covers videos and stills. Spoken matching layers exact keywords over on-device semantic matching of transcript segments — quote the words said, or paraphrase them; transcripts are created automatically while indexing (and by inspect_media and add_captions), so coverage grows as indexing completes. The two groups rank independently and are never blended. Scores are uncalibrated — use them for ordering only.

Hits are source-second ranges. To place exactly that moment, multiply by fps and pass as trimStartFrame/trimEndFrame with a matching durationFrames to add_clips or set_clip_properties. Image hits have no time range.

status reports the visual index: ready | indexing | modelNotInstalled | downloadingModel | preparing | disabled | failed. When not ready, moments may be empty or incomplete (compare indexedAssets to indexableAssets) — report that instead of concluding the footage doesn't exist, and don't poll in a loop. Spoken results work regardless of status.

### `add_clips`

- Source case: `ToolName.addClips`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:126`
- Availability: In-app agent and MCP

Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). The whole batch is one undo step.

trackIndex is optional. Omit it on all entries and the tool auto-creates the needed tracks — one shared video track for visual entries and one shared audio track (matches the captioning pattern in add_texts). To target existing tracks, set trackIndex on every entry. Mixing (some entries specify, others omit) is rejected — split into two calls. Existing caption tracks are protected; don't place media on them while reorganizing a timeline.

Tracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior.

### `insert_clips`

- Source case: `ToolName.insertClips`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:152`
- Availability: In-app agent and MCP

Inserts one or more media assets at a single point and RIPPLES: every clip at or after atFrame is pushed right to open a gap, so nothing is overwritten. This is the non-destructive counterpart to add_clips (which clears the landing region, trimming/splitting/removing whatever's there). Use insert_clips to splice footage in without losing existing clips; use add_clips to fill empty space or deliberately overwrite.

Entries are laid end-to-end starting at atFrame on the target track (entry[0] at atFrame, entry[1] immediately after, ...). The push equals the sum of the entries' durations and is applied to the target track, every sync-locked track, AND the audio track any auto-created linked audio lands on — so a clip and its linked audio stay aligned. As in add_clips, a video asset with audio spawns a linked audio clip. One undoable action; one bad entry rejects the whole call with no partial state.

trackIndex is required — ripple needs an existing track to push. Do not target caption tracks while reorganizing a timeline. For placement into empty space, use add_clips.

### `remove_clips`

- Source case: `ToolName.removeClips`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:178`
- Availability: In-app agent and MCP

Removes one or more clips by ID as a single undoable action. Any clip that belongs to a link group (e.g. a video with its paired audio) takes its whole group with it, matching the UI's linked-delete behavior. Caption clips are protected by default; don't remove them during timeline reorganization unless the user explicitly asked to delete captions.

### `remove_tracks`

- Source case: `ToolName.removeTracks`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:193`
- Availability: In-app agent and MCP

Removes whole tracks and every clip on them in one undoable action. Linked partners on OTHER tracks are not removed. Remaining track indexes shift down after removal. Caption tracks are protected by default; don't remove them during timeline reorganization unless the user explicitly asked to delete captions.

### `move_clips`

- Source case: `ToolName.moveClips`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:208`
- Availability: In-app agent and MCP

Moves one or more clips to a new track and/or frame position. Single undoable action. Each move specifies the clip ID and at least one of toTrack (must be compatible with the clip's media type) and toFrame. Overlap on the destination is resolved as in add_clips (existing clips on the destination track are trimmed/split/removed). Linked partners follow the named clip: startFrame propagates as a delta to preserve l-cut / j-cut offsets; tracks stay with the named clip. Caption clips and caption tracks are protected by default; only move them when intentionally preserving caption timing.

### `apply_layout`

- Source case: `ToolName.applyLayout`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:231`
- Availability: In-app agent and MCP

Arrange multiple clips into a common multi-video layout (split screen, picture-in-picture, grid) in one undoable action — the fast path for composing several videos in one frame. Use this instead of hand-setting transforms and screenshot-checking alignment with inspect_timeline.

You pick a named layout and assign a clip to each of its slots; the tool computes every transform and crop so each clip FILLS its region edge-to-edge WITHOUT stretching — the source is cropped to the slot's shape (cover), like a layout template the videos are dropped into. Pass fit='fit' to letterbox the whole source inside its slot instead (no crop, may leave bars) — use only when the full frame must stay visible (e.g. a screen recording).

The crop is centered by default. When that chops off something important (a face cropped at the forehead, a subject off to one side), bias which part survives: 'anchor' is a coarse shortcut ('top' keeps the top, etc.), while anchorX/anchorY (0–1) give continuous control for in-between framing — e.g. anchorY 0.35 moves the crop only slightly toward the top, not all the way. To nudge framing after the fact, call apply_layout again with adjusted anchorX/anchorY (clipIds mode re-crops in place).

Two modes (don't mix across slots):
• Place new clips: give each slot a 'mediaRef' (from get_media) plus top-level startFrame (default 0) and durationFrames. Creates one stacked video track per slot at that time range; for PIP the inset is placed on top automatically. Video clips bring their linked audio.
• Re-layout existing clips: give each slot 'clipIds' — one or more existing clips, all framed into that slot (handy when a track holds several sequential takes). Only transforms/crop change — timing and tracks are untouched (so existing track order decides stacking).

Every slot of the chosen layout must be filled. Layouts and their slot names:
  • full — main
  • side_by_side — left, right
  • top_bottom — top, bottom
  • pip_bottom_right / pip_bottom_left / pip_top_right / pip_top_left — main, inset
  • grid_2x2 — top_left, top_right, bottom_left, bottom_right
  • main_sidebar — main (70%), sidebar (30%)
  • three_up — left, center, right

### `set_clip_properties`

- Source case: `ToolName.setClipProperties`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:275`
- Availability: In-app agent and MCP

Apply the same generic clip property values to one or more clips in a single undoable action. Pass any combination of durationFrames, trimStartFrame, trimEndFrame, speed, volume, opacity, transform, or blendMode (video/image clips only). For text content, typography, captions, and text animation, use update_text.

NOT for preview layout — split screen, picture-in-picture, grid, sidebar, and any multi-clip canvas arrangement belong to apply_layout, which sets transform and crop together. Do not use transform here (or set_keyframes position/scale/crop) to build those layouts.

All values apply to every clip in clipIds; for per-clip differences, make separate calls. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volume and opacity are 0.0–1.0. transform is for rare single-clip tweaks only — 0–1 normalized canvas coords, partial merge; flipHorizontal/flipVertical mirror across the axis.

For moves and start-frame changes, use move_clips. For animated values (keyframes), use set_keyframes — setting volume or opacity here clears any existing keyframe track on that property.

Timing changes (durationFrames, trimStartFrame, trimEndFrame, speed) on a linked clip carry over to its linked partner so audio/video stay in sync — same as the timeline UI. Per-clip fields (volume, opacity, transform, blendMode) don't propagate. trim and speed are skipped for text partners.

### `set_keyframes`

- Source case: `ToolName.setKeyframes`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:312`
- Availability: In-app agent and MCP

Set animated keyframes on one property of one clip. Replaces the existing keyframe track for that property (pass an empty array to clear). Frames are CLIP-RELATIVE offsets (0 = first frame of the clip), so keyframes follow the clip when it moves. Rows are sorted by frame internally and the LAST row for any duplicate frame wins. Values must be finite numbers. Each row is `[frame, ...values, interp?]` where interp ∈ {linear, hold, smooth} (default smooth).

Properties and their value layouts:
  • volume `[frame, value]` — value 0.0–1.0
  • opacity `[frame, value]` — value 0.0–1.0
  • rotation `[frame, degrees]` — clockwise degrees
  • position `[frame, topLeftX, topLeftY]` — TOP-LEFT corner in 0–1 normalized canvas coords. NOT the center. (Default static transform centers a full-canvas clip, so top-left of the static is (0, 0); a centered half-size clip has top-left (0.25, 0.25).)
  • scale `[frame, width, height]` — clip's normalized width and height in 0–1 canvas coords (1.0 = fills the canvas axis). NOT a scale factor.
  • crop `[frame, top, right, bottom, left]` — side insets in 0–1 of the source media.

Motion keyframes (position/scale/rotation) override the static `transform` value when active.

### `split_clips`

- Source case: `ToolName.splitClips`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:332`
- Availability: In-app agent and MCP

Splits clips into two at one or more cut points, all in a single undoable action. A split only inserts a boundary — it never trims media or moves clips, so unlike ripple_delete_ranges nothing shifts and there's no gap to close.

Two modes — pass exactly one:
• splits: an array of {clipId, atFrame} (project frames). Use when you know the clip IDs.
• trackIndex + frames: cut one track at the given project frames; each frame is matched to whichever clip on that track contains it. Pairs naturally with get_transcript / get_timeline project frames.

Every frame must fall strictly between a clip's start and end. Multiple cuts on the SAME clip are allowed — pass all the frames at once and each is resolved against the current sub-clips. Duplicate cut points are ignored. Linked audio/video partners are split at the same frame so A/V stays in sync, and the right halves are regrouped into their own link pair. Caption clips are protected by default. One bad cut point rejects the whole call with no partial state.

### `ripple_delete_ranges`

- Source case: `ToolName.rippleDeleteRanges`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:359`
- Availability: In-app agent and MCP

Cuts one or more exact frame/second ranges out and closes the gaps in one undoable action. Use it only when the span is not word-aligned, such as visual-only dead air, room tone, or a visible pause with no transcript word row. For filler words, stutters, retakes, and any spoken text that appears in get_transcript, use remove_words with the word indices instead.

Two modes — pass exactly one of clipId or trackIndex:
• trackIndex: ranges are PROJECT frames and may span any number of clips on that track. Use project-frame ranges only after you have verified the span cannot be represented as get_transcript word indices. units must be 'frames'.
• clipId: ranges are cut within that single clip only, clamped to its visible span. Allows units 'seconds' (source-media seconds, e.g. inspect_media WITHOUT a clipId or search_media hits); 'frames' = project frames.

Overlapping ranges merge. Linked audio/video partners of every touched clip are cut on the same span so A/V stays in sync. Remaining clips shift left to close every gap; sync-locked tracks shift along to preserve alignment (their content isn't cut). Refuses without changing anything if a sync-locked track can't absorb the shift (e.g. it would move past frame 0). The refusal names the blocking track (e.g. "V2") — map it to its index via get_timeline and pass that index in ignoreSyncLockedTracks to cut anyway, leaving that track's clips in place. Returns the anchor track's post-cut layout (clip ids/frames) so you don't need to re-read.

### `remove_words`

- Source case: `ToolName.removeWords`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:381`
- Availability: In-app agent and MCP

Cut speech by the word, Descript-style — the primary tool for text-based editing (filler words, flubbed sentences, dropped retakes, tightening a ramble). You name WHICH words to remove by their get_transcript index; this resolves them to frames, removes the surrounding pause so survivors don't end up double-spaced, merges adjacent removals, cuts linked A/V partners, and closes the gaps. You never deal in frame numbers — that's the whole point versus ripple_delete_ranges.

Workflow: call get_transcript, read it as prose, then pass the indices of the words to drop. Words across multiple clips on ONE track are handled in a single undoable action, and any linked A/V partner (e.g. the video paired with this audio) is cut automatically. Edit one track at a time: if your indices span multiple unlinked tracks (e.g. two separate mics), the call is refused — cut each track in its own call, or link the tracks into one unit first. After it runs, indices have shifted — re-read get_transcript before another remove_words.

When to use which: remove_words for anything you can point at in the transcript; ripple_delete_ranges only for spans that aren't word-aligned (e.g. a visual-only dead-air gap). Verify reworded retakes and sub-frame seam fragments against the word list, not a summary.

### `sync_audio`

- Source case: `ToolName.syncAudio`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:401`
- Availability: In-app agent and MCP

Align one or more clips to a reference clip by cross-correlating audio and shifting targets on the timeline. referenceClipId stays put — use for dual-system sound (camera + external audio) or multicam. Returns offsetFrames and confidence (0–1) per target; refuses weak matches.

### `undo`

- Source case: `ToolName.undo`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:415`
- Availability: In-app agent and MCP

Reverts the assistant's most recent timeline edit (a cut, move, trim, split, or clip/text/caption add) as one step. The recovery path when an edit went too far — e.g. a ripple_delete_ranges removed more than intended. Verify a cut first (get_transcript reflects the post-cut audio), then undo if it overshot, then retry with corrected ranges.

Undoes only edits the assistant made this session, most-recent-first — it never touches the user's own manual edits, and refuses if the latest change wasn't the assistant's. After undoing, the timeline is restored to its state before that edit; the ids/frames the edit returned are no longer valid, so re-read with get_timeline or get_transcript if you'll edit again. Takes no arguments.

### `add_texts`

- Source case: `ToolName.addTexts`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:420`
- Availability: In-app agent and MCP

Adds one or more text clips (titles, captions, lower-thirds) in a single undoable action. Text renders as an overlay on top of visual media. Transform uses 0–1 normalized canvas coords: (0.5,0.5) is center, (0.5,0.1) top-center, (0.5,0.9) bottom-center. Omit transform to center + auto-fit. Put centerX/centerY inside transform to reposition with auto-fit size (common for lower-thirds). Put all four transform fields inside transform to override the box entirely. Colors are hex '#RRGGBB' or '#RRGGBBAA'.

trackIndex is optional. Omit it on all entries and the tool auto-creates one new video track at the top and places all text clips there — the common case for captions. To target existing tracks, set trackIndex on every entry (audio tracks rejected). Mixing (some entries specify, others omit) is rejected — split into two calls.

Tracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing (or earlier-batch) clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior. To show multiple text clips at the same time (stacked titles, simultaneous labels), put each on a DIFFERENT trackIndex so they layer instead of trimming each other.

For captioning spoken audio, prefer add_captions — it transcribes and places styled caption clips in one call. Use add_texts only for bespoke text (titles, lower-thirds) or captioning a custom range by hand. Unknown fields are rejected.

### `update_text`

- Source case: `ToolName.updateText`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:451`
- Availability: In-app agent and MCP

Updates text clips or a captionGroupId. Use for content, typography, color, outline color, background color, animation, or text-box transform. Content/typography changes auto-fit the box unless transform is passed. Unknown fields are rejected.

### `add_captions`

- Source case: `ToolName.addCaptions`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:475`
- Availability: In-app agent and MCP

Auto-caption spoken audio: transcribes and places styled caption clips on a new track — the same pipeline as the editor's Captions tab. This is the reliable path for 'caption this'; prefer it over hand-placing add_texts from a transcript. The transcriptionProvider defaults to the user's caption setting; pass local for on-device speech or volcengine for configured Seed ASR. Use maxCharacters for requests like 'at most 10 characters per caption' instead of splitting captions manually. When the user asks for short/readable captions but gives no exact limit, choose maxCharacters from the spoken language, the timeline aspect ratio/resolution, and fontSize: narrow vertical video or larger text needs fewer characters; wide landscape video or smaller text can use more; CJK text generally fits fewer visible characters than alphabetic text. Use maxWords for word-count style constraints. Per-word animations are timed from transcript. Omit clipIds to auto-pick the track with the most speech; pass clipIds to caption specific clips.

### `align_captions`

- Source case: `ToolName.alignCaptions`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:495`
- Availability: In-app agent and MCP when Volcengine Speech is configured

Retimes existing caption text clips with Volcengine Seed ASR word timestamps. Use when captions already exist but their timing drifts or needs precise audio alignment. This preserves caption text and style; it only adjusts startFrame, durationFrames, and per-word animation timings. Requires a configured Volcengine Speech API key, so this tool is hidden when that backend is unavailable. If there are no existing caption clips, call add_captions instead.

### `export_project`

- Source case: `ToolName.exportProject`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:507`
- Availability: In-app agent and MCP

Exports from the current project using the same modes as the Export dialog. mode defaults to video. video renders H.264, H.265, or ProRes; xml writes XMEML timeline XML; fcpxml writes FCPXML; palmier writes a self-contained .palmier project package. For timeline interchange, pick the format by the target editor: Premiere Pro -> xml; DaVinci Resolve or Final Cut Pro -> fcpxml (fcpxml also carries text, transforms, crop, opacity, and keyframes that xml cannot). Omit outputPath to write a unique file to ~/Downloads. Existing direct outputPath files are overwritten by default to match the UI save flow; pass overwrite=false to refuse. video renders in the background and returns status=started with the destination path; the app posts a system notification on completion or failure, so do not expect a final result inline. xml, fcpxml, and palmier finish before returning and report their result inline.

### `generate_video`

- Source case: `ToolName.generateVideo`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:520`
- Availability: In-app agent and MCP

Starts an async AI video generation. Returns a placeholder asset ID immediately; generation runs in the background and the asset becomes usable in add_clips once ready. Costs real money and is not undoable.

### `generate_image`

- Source case: `ToolName.generateImage`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:544`
- Availability: In-app agent and MCP

Starts an async AI image generation. Returns a placeholder asset ID immediately; generation runs in the background. Costs real money and is not undoable.

### `generate_audio`

- Source case: `ToolName.generateAudio`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:561`
- Availability: In-app agent and MCP

Starts an async AI audio generation: text-to-speech, text-to-music, or video-to-music (scoring a video). Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS models (elevenlabs-tts-v3, gemini-3.1-flash-tts) convert the prompt into speech and accept a 'voice'. Music models (lyria3-pro, minimax-music-v2.6, elevenlabs-music, sonilo-v1.1-video-to-music) generate tracks from a prompt; include lyrics/tempo/vocal style in the prompt for Lyria 3 Pro, pass 'lyrics' for MiniMax vocals, or set 'instrumental' true when the selected model supports it. Video-to-audio models (inputs include 'video' — see list_models, e.g. sonilo-v1.1-video-to-music, mirelo-sfx-v1.5-video-to-audio) generate audio that matches a VIDEO: provide a timeline span via videoSourceStartFrame+videoSourceEndFrame (e.g. to score the timeline), or a video asset via videoSourceMediaRef; the prompt is then an optional style guide. PLACEMENT: when you pass a timeline span, the result is placed on the timeline automatically at that span (no add_clips needed); for a media-asset source or a plain text-to-speech/music result, the asset lands in the library and you place it with add_clips. Use list_models with type='audio' to see each model's 'inputs', category, and voices. Costs real money and is not undoable.

### `upscale_media`

- Source case: `ToolName.upscaleMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:582`
- Availability: In-app agent and MCP

Upscales an existing video or image asset to higher resolution using an AI upscaler. Returns a placeholder asset ID immediately; the upscaled asset appears in get_media once ready. Use list_models with type='upscale' to pick a model that supports the asset's type. Costs real money and is not undoable.

### `import_media`

- Source case: `ToolName.importMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:594`
- Availability: In-app agent and MCP

Imports external media into the project's library — the bridge for assets coming from other MCP servers (stock libraries, music services, web search) or local files the user already has. The 'source' object must set exactly one of: url (HTTPS only — downloaded in the background, the dominant case; max 1 GB), path (absolute local file path — copied into the project in the background; may also be a directory, which is imported recursively, mirroring its subfolder structure as media folders), or bytes (base64-encoded inline data — max ~15 MB of base64 ≈ 11 MB binary; use url/path for anything larger). For url, type is inferred from the URL path's file extension unless source.mimeType is set as an override (needed for signed URLs whose path has no usable extension). For bytes, source.mimeType is required.

Supported types and extensions: video (mov, mp4, m4v), audio (mp3, wav, aac, m4a, aiff, aifc, flac), image (png, jpg, jpeg, tiff, heic). Anything else is rejected — the caller must transcode externally.

Returns a placeholder asset id immediately for URL and file-path imports; the asset becomes usable in add_clips once ready (same async pattern as generate_*). Directory and bytes imports finalize synchronously. Costs nothing.

### `list_folders`

- Source case: `ToolName.listFolders`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:615`
- Availability: In-app agent and MCP

Lists every folder in the media panel as {id, name, parentFolderId}. Folders are nested (parentFolderId is nil for top-level). Use to find an existing folder by name before generating new media.

### `create_folder`

- Source case: `ToolName.createFolder`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:620`
- Availability: In-app agent and MCP

Creates folders in the media panel. Pass either name/parentFolderId for one folder or entries for multiple folders, not both. Direct form returns one folder; entries returns { folders }. Undoable. Use to organize related generations (e.g. 'Hero shot variations'). Don't create folders for unrelated concepts.

### `move_to_folder`

- Source case: `ToolName.moveToFolder`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:642`
- Availability: In-app agent and MCP

Moves media assets to folders. Pass either assetIds/folderId for one destination or entries for multiple destinations, not both. Omit folderId to move to root. Undoable.

### `rename_media`

- Source case: `ToolName.renameMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:672`
- Availability: In-app agent and MCP

Renames media assets in the library. Pass either mediaRef/name for one asset or entries for multiple assets, not both. Undoable.

### `rename_folder`

- Source case: `ToolName.renameFolder`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:694`
- Availability: In-app agent and MCP

Renames folders in the media panel. Pass either folderId/name for one folder or entries for multiple folders, not both. Undoable.

### `delete_media`

- Source case: `ToolName.deleteMedia`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:716`
- Availability: In-app agent and MCP

Deletes media assets from the library. Any clips referencing them are removed from the timeline in the same undoable action.

### `delete_folder`

- Source case: `ToolName.deleteFolder`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:730`
- Availability: In-app agent and MCP

Deletes folders and everything inside them (subfolders and assets). Clips referencing any deleted asset are removed from the timeline in the same undoable action.

### `list_models`

- Source case: `ToolName.listModels`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:744`
- Availability: In-app agent and MCP

Lists AI models with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support, voices/category for audio, upscaler speed). Always call before generate_video, generate_image, generate_audio, or upscale_media so the model you pick actually supports the constraints you need. Returns { models, loaded } and may include audioProviderError when a configured audio provider failed to load. If loaded=false, no configured provider has supplied a model catalog yet. Ask the user to configure the relevant provider credential, then retry.

### `apply_effect`

- Source case: `ToolName.applyEffect`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:753`
- Availability: In-app agent and MCP

Apply non-color effects (blur, sharpen, stylize, detail, key) to video/image clips as a live, editable effect stack — the looks/FX path, distinct from apply_color (grading). MERGES: each effect you pass is added or updated by type; effects you don't mention are left in place. Pass enabled:false to bypass one without removing it, or list its type in `remove` to delete it. Out-of-range params are clamped; params you omit keep their current (or default) value. Effects render in a fixed canonical order regardless of the order you pass them. Undoable. Verify with inspect_timeline.

Available effects — type: param (range, default):
[generated from EffectRegistry at runtime]

### `apply_color`

- Source case: `ToolName.applyColor`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:786`
- Availability: In-app agent and MCP

Author/refine a color grade on video/image clips with named controls — the colorist path, distinct from apply_effect (looks/FX). MERGES with the clip's current grade: only the params you pass change, the rest are preserved, so you can nudge one knob at a time (pass reset:true to start from neutral). Applies as live, editable color.* effects; non-color effects untouched. Iterate: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat. Undoable. All knobs optional. Color WHEELS use HUE (0–360°, standard) + AMOUNT per tonal zone — to push shadows teal, set shadowsHue 180 and shadowsAmount ~0.15. CURVES (master + per-channel R/G/B) give precise tone shaping — per-channel curves are tone-selective (e.g. pull the blue curve down in the highlights to tame a bright sky). HUE CURVES do secondary/qualified correction — target a source hue and shift its hue/saturation/lightness (e.g. desaturate greens, warm the skin) without a mask; pair with inspect_color's hueHistogram to find which hues are present. LUT applies a .cube film-look pack on top of the grade.

### `inspect_color`

- Source case: `ToolName.inspectColor`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:851`
- Availability: In-app agent and MCP

Measure color scopes of a timeline clip's current graded look (clipId) OR a raw media asset (mediaRef) — black/white points, % clipping, mean & per-channel levels, shadow/mid/highlight color tilt, saturation, warm-cool / green-magenta balance, and a saturation-weighted hueHistogram (12 bins of 30° from 0°/red — shows which hues are present, e.g. an orange cluster = skin, a cyan/blue cluster = sky) — and return the rendered frame too. Use this to grade by the numbers instead of eyeballing, to find hues to target with apply_color's hueCurves, or to measure footage/references before grading. clipId applies the clip's effects (graded look); mediaRef measures the raw asset. Pass a reference image/video id to also measure it and get the subject−reference GAP plus hints that map onto apply_color knobs. The loop: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat until the gap is small.

### `set_project_settings`

- Source case: `ToolName.setProjectSettings`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:863`
- Availability: In-app agent and MCP

Change the project's frame rate, resolution, or aspect ratio. Pass any combination of fps, explicit width+height, aspectRatio, and quality. aspectRatio and explicit width/height are mutually exclusive; quality scales the current aspect ratio (or the selected preset when combined with aspectRatio). The timeline's existing clips are re-fitted automatically: auto-fit transforms recalculate for the new canvas size, and all frame positions/durations rescale when fps changes. Undoable.

### `send_feedback`

- Source case: `ToolName.sendFeedback`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:876`
- Availability: In-app agent and MCP

Report an agent limitation or bug to the Palmier team so they can improve the product. Use when you can't do what the user asked because a capability or tool is missing or behaves wrong, the result is clearly off, or the user is plainly hitting a rough edge. This sends directly — there is no user confirmation step — so PARAPHRASE in your own words: never include verbatim user messages, prompts, file paths, media, transcript text, or any project content. App/OS version and your recent tool names are attached automatically. Use sparingly: at most once per distinct issue.

### `read_skill`

- Source case: `ToolName.readSkill`
- Source line: `Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift:906`
- Availability: In-app agent only

Load the full instructions for one of the skills listed under # Skills in your system prompt. Call this before starting a task that matches a skill's description, then follow the returned procedure. Pass the id exactly as listed.

