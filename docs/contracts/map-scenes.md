# Geographic map scenes

`build_map_scene` produces a silent, locally rendered H.264 geography video. `MapSceneSpec` owns validation, canonical input and geographic calculations; `MapSceneMotion` owns route/object timing. The generated asset retains a `MapSceneRecord` in `media.json`, including input, atlas/renderer versions, image fingerprints and rendered-video fingerprint. `read_map_scene` reads that record after manifest restoration; revisions generate another asset.

## Geography and visual contract

- `list_map_regions` searches the bundled public-domain Natural Earth atlas: 177 country features at 1:110m and 294 available subdivisions at 1:50m. IDs are `country:GEO`, `subdivision:US-GA`, etc. Ambiguous aliases refuse. The 12 existing Malaysian editorial place anchors remain available. Explicit WGS-84 coordinates support other towns/ports; they are caller supplied, not geocoded.
- Atlas components expose index, center and bounds. `componentIndices` can highlight separate land masses of Malaysia. A custom region needs a nondegenerate, closed 4–4096 vertex `[longitude,latitude]` polygon. Custom polygon holes and automatic administrative/geocoding downloads are not supplied. Region event IDs are unique; different IDs allow repeated highlights of one geographic region.
- `MapProjection` owns a north-up equirectangular plane, circular longitude origin and a shared affine camera transform. Camera keys support center, logarithmically interpolated zoom, rotation and simulated planar tilt. Incoming easing is linear, easeInOut, easeOut, or hold. This is not globe geometry, a terrain mesh, navigation data, or a claim that atlas borders settle disputed boundaries.
- Country outlines and public-domain relief form the background. An optional ready library image can replace the background with explicit west/south/east/north registration. Region image fills clip to outlines. Pins, routes and object anchors follow the same camera transform; geographic labels remain upright in screen space.
- Routes use straight/curved geometry or via coordinates, timed reveals and optional labels. An approximate haversine endpoint distance is separate from traveled route distance. `kind:sourced` needs nonempty claim IDs; identifiers alone are not evidence verification. A plan's existing source ledger remains the factual review mechanism.
- Objects support ship, airplane, truck, train, package, person, factory, money, tank, arrow, pin, circle, gunfire, explosion, heat, rain, image and flag. Image/flag objects need an image asset. An object has exactly one anchor, routeId or timed waypoint path. Route traversal may loop; timed waypoints do not. Optional tangent rotation follows the camera-transformed path. Built-in symbols are vector drawings; effects are deterministic frame functions.
- Timed screen/geographic text supports bold outlined typography, multiline wrapping and none/fade/pop/slide/typewriter entrances. Screen coordinates are normalized with a top-left origin. Caption tools provide transcript-aligned spoken phrases separately.

## Time, limits and failure

Scene cue frames use explicit integer fps (default: timeline fps, 1–120). The scene lasts at least one frame and at most 180 seconds at that fps, up to 21,600 frames. Start/reveal is inclusive; endFrame is exclusive. Object route arrival is the last visible frame; waypoints must increase strictly within the visible window. Camera frames are unique. Routes must finish their reveal before their endFrame. Typewriter is supported only for text.

Canvas dimensions are 320–3840 by 180–3840, at most 8,294,400 pixels. A scene supports 64 place anchors, 64 regions, 64 routes, 64 objects, 64 text cues and 128 camera keys. At most 16 custom images are read with 64 MiB per-file and 128 MiB aggregate input limits. Decoded images have a separate 128 MiB ceiling. One renderer permit bounds resource preparation and encoding. Country geography is generalized; close-ups may need a better registered source image/custom outline.

Types, finite values, colors, IDs, geometry, dimensions, windows and supported combinations validate before mutation. Unknown nested tool fields refuse. Missing/corrupt image files, encoder errors and cancellation return failures. Rendered output fingerprints prevent a changed/missing video file from becoming an identical-retry no-op.

## Publication and ownership

`EditorViewModel.prepareMapScene` is the shared owning operation. It acquires a `ProjectPackageCoordinator` mutation lease, snapshots configuration and source asset identities, resolves the atlas/spec off-main, renders off-main, and revalidates project/timeline configuration, sources, lifecycle and cancellation after suspension. The CoreGraphics/CoreText canvas is worker owned and transfers exclusively into the encoder; it is not declared Sendable or shared across concurrent workers. Image bytes are fingerprinted again at render completion.

The producer owns a unique stage until it passes it to `commitStagedProjectMedia`. The installer owns cleanup even if the render completed just before cancellation. Installation uses create-new package semantics and awaits cleanup/rollback; no feature code writes directly into a live package. Publication installs asset metadata and optional placement together in one `EditorUndo` library snapshot action. Failed/refused/cancelled requests create no asset/clip/undo step. Backing bytes remain for redo.

For placement, `ClipPlacement` converts source duration to complete timeline frames by rounding down. A result shorter than one timeline frame refuses before rendering. Placement uses an available visible video track with no overlap, or creates a new visual track; existing clips are not overwritten. Unrelated edits during rendering are captured at publication and survive map undo. Identical input/resources reuse a matching fingerprinted asset; matching placement is a no-op. Name applies only to a newly generated asset. Changed input generates a new asset; the agent explicitly targets any clip replacement.

## Agent workflow

Three offline built-in skills cover map story patterns, motion-object choreography, and narration/synchronization. They are included in the in-app skill scan and `read_skill`. The external MCP server receives map workflow instructions and the same map tools. See [reference study](../design/map-reference-study.md).

Use available speech voices, pinned approved narration intent, actual transcription/beat timing, phrase captions, and `mix_audio`. Map rendering creates no soundtrack. Follow normal storyboard inspection/approval for finished productions, then assemble, review and await completed export. Atlas attribution does not establish rights to custom images. Voice intelligibility and creative similarity require playback/audition.

## Narration measurement

Mixed-audio analysis must decode the complete requested range when narration uses a different sample rate from delivery. `CompositionBuilder.buildAudio` supplies a 4,096-sample muted media tail at 48 kHz after the last planned audio content. Empty trailing edits cannot extend an AVFoundation composition track. The read-ahead borrows a real composition segment, repeats it only when needed with a 128-copy bound, and exists only in the measurement composition. Ordinary playback/export construction is unchanged.

`AudioTrackReader.readMix` feeds the resampler past the cut but emits exactly the requested samples, including planned silence. At most one output sample of endpoint rounding may be filled; a genuinely incomplete decode still refuses with expected/decoded counts. Regressions cover 22.05 kHz sentences, a one-frame pause, a visual tail, an earlier 48 kHz music bed, and a one-frame effect at 120 fps.

`mix_audio` measures the sum and refuses a loudness target that would exceed the true-peak ceiling. It does not apply a limiter. The narration playbook directs the agent to choose a suitable lower target, measure again, and report the target actually achieved.

The retained MCP proof is opt-in through `COMPOSITOR_MAP_PROOF_DIRECTORY` and uses a fresh destination per run. `COMPOSITOR_MAP_PROOF_ENGINE` defaults to `system`; `piper` requires `COMPOSITOR_MAP_PROOF_VOICE`. `COMPOSITOR_MAP_PROOF_TARGET_LUFS` defaults to -18. `COMPOSITOR_MAP_REQUIRE_BUNDLED_MIX=1` requires the bundled-speech trait, an actual app host, measured voice activity, and a successful mix rather than accepting the ordinary unbundled refusal. The proof synchronizes two visual sections to generated sentence durations; it does not certify word alignment, narrator performance, or the native agent UI.

## Verification

Automated gates: `swift build`; focused `MapSceneTests|MapSceneRendererTests|MapSceneMCPTests|MapScenePublicationTests|FilmmakingPlaybooksTests|GenerateSpeechToolTests`; full `swift test`; `BundledSpeech` build and relevant tests; resource lookup/packaging; relevant Thread Sanitizer tests; guidance lint and diff checks. Record actual results after running these gates; this contract is not itself a pass claim.

The MCP suites use isolated Client/Server in-memory transports, protocol discovery/calls, independent library/timeline/media/manifest readback, invalid arguments, no-op retries, undo, native redo and Save As. Rendering tests cover country-window pixels, north-up custom imagery, labels, moving ships/effects and encoded source timing. Publication gates coordinate cancellation and stale state without sleeps.

Manual plan (unverified until confirmed):

1. Use a disposable vertical project. Ask the agent for a sourced map explainer, choose an available voice and approve its prepared storyboard. Inspect both Malaysia land masses and the Georgia ambiguity error. Check keyboard focus and Escape/cancel in playbook selection and storyboard review; cancelled review must preserve existing edits.
2. Scrub/play a scene with a moving camera, route, ship/package, highlight and large title. Check reveal/arrival/end frames, labels, flag masks, safe margins, coastlines and camera continuity. Try a supplied transparent wildlife/other object image.
3. Play the finished narration/captions/SFX/music together. Check pronunciations, emphasis, word-to-visual timing, intelligibility and audio tails; inspect the encoded export.
4. Repeat a request and verify no duplicate asset/clip/undo step. Undo/redo, Save As and reopen; inspect the saved spec and backing video. Keep another edit on the timeline during generation.
5. Cancel while rendering; repoint an image or switch timeline configuration; close/cancel close during rendering. Confirm visible failure/cancellation, cleanup and preservation of existing edits/media. Exercise sleep/wake and app deactivation during a long render.
