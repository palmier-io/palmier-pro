# Agent video quality: engineering issues and implementation backlog

Date: 2026-10-01. Inspected base commit: `75ef7d8`, plus active working-tree changes.

This is a standalone technical backlog. Each issue explains the failure mechanism, the responsible code, the implementation work, and the evidence required to close it. All implementation checkboxes are pending.

## 1. Engineering diagnosis

Professional prompt-to-video output requires several systems to agree: the creative brief, selected footage, exact timeline edits, audio processing, and the rendered result. A stronger chat model can improve editorial decisions only when it receives usable evidence and can reliably execute those decisions.

The current implementation has both concrete defects and incomplete production workflows:

- Some model routes discard the images needed to judge footage.
- Some advertised processing depends on unavailable services or optional build resources.
- Audio measurement, gain application, time conversion, and cache ownership contain correctness problems.
- Search returns potentially usable media; it does not establish that the selected shot satisfies the brief.
- Long-running operations and quality review are not yet coordinated into a durable production run.

The defects below are established by source inspection. Their contribution to the user's particular failed edit still needs a replay of that prompt, endpoint, input media, and resulting project. No live comparison with Cursor or Claude Code was performed.

### Existing architecture to preserve

The in-app agent streams model responses through `AgentService`, dispatches tools through `ToolExecutor`, and edits the same domain model used by the UI. External agents enter through `MCPService` and use that shared executor. `EditorUndo` owns editor undo grouping. `GenerationService`, media import, and `ExportQueue` already provide parts of the asynchronous workflow. Project media installation belongs to `ProjectPackageCoordinator`.

Extend these owners. The proposed production coordinator should connect existing operations, not create separate implementations of placement, processing, or rendering.

### Concurrent work observed

Another agent is actively adding edit plans, unified shot candidates, Pixabay support, transitions, persistence, and tests. Relevant files include:

- `Agent/Plans/EditPlan.swift`, `Agent/Tools/ToolExecutor+Plan.swift`, and `Editor/ViewModel/EditorViewModel+EditPlans.swift`.
- `Agent/Retrieval/ShotCandidates.swift` and `Agent/Tools/ToolExecutor+ShotCandidates.swift`.
- `MediaSources/PixabayProvider.swift` and shared stock-provider plumbing.
- `Models/TimelineTransition.swift`, `Agent/Tools/ToolExecutor+Transition.swift`, and `Editor/ViewModel/EditorViewModel+Transitions.swift`.

At the time of inspection, `apply_plan` checks readiness and returns `applied: false`; unified shot retrieval returns metadata/evidence records, without remote content inspection. These are in-progress contracts. Recheck them before implementing dependent tickets. Source line numbers can move during that work.

## 2. P0: repair evidence delivery and audio correctness

### VQ-001 — Inspection images disappear on custom model routes

**Owner:** `Agent/Clients`. **Priority:** P0.

**Code:** [`OpenAIChatCompletionsProvider.swift:76–87,129–135`](../Sources/CompositorPro/Agent/Clients/OpenAIChatCompletionsProvider.swift#L76); [`ToolResult.swift:5–8`](../Sources/CompositorPro/Agent/Tools/ToolResult.swift#L5).

**Technical explanation:** Inspection tools correctly return `ToolResult.Block.image` alongside metadata. The custom Chat Completions adapter passes the result through `toolResultText`, which selects only `.text` blocks. The image never reaches the next model request. User-attached images use a different path and are preserved, which can hide this defect during basic vision testing. The built-in Anthropic and OpenAI Responses adapters preserve tool-result images.

**User impact:** The agent can call an inspection tool successfully and still choose or describe footage using metadata rather than the picture. Better reasoning cannot recover pixels removed by the adapter.

**Implementation TODO:**

- [ ] Preserve tool-result images using the endpoint's verified multimodal format. If images must be placed in a following user-content message, associate each with its tool-call ID, media ID, and frame time, and preserve valid tool-result ordering.
- [ ] Declare vision support for each route; return an explicit capability limitation when the route cannot accept inspection images.
- [ ] Preserve text, errors, images, and their ordering through multiple calls and conversation replay. Keep base64 image data out of text-only substitutions and logs.

**Done when:** A loopback transport test receives actual image data from a tool result, including image-only and mixed results. A controlled recognition test selects the correct picture despite misleading filenames. Extend [`CustomAgentModelTests`](../Tests/CompositorProTests/Agent/CustomAgentModelTests.swift#L78), whose current image test covers a user attachment and a text-only tool result.

### VQ-002 — Capabilities do not form one reliable planning contract

**Owner:** `Backend`, `Generation`, `Audio`, and shared tool discovery. **Priority:** P0.

**Code:** [`HostedServices.swift:14`](../Sources/CompositorPro/Backend/HostedServices.swift#L14), [`ToolExecutor+Generate.swift:35–42`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Generate.swift#L35), [`AudioEnhancer.swift:21–40`](../Sources/CompositorPro/Audio/AudioEnhancer.swift#L21), [`Package.swift`](../Package.swift).

**Technical explanation:** Chat, media generation, and local DSP use different dependencies. Hosted generation is disabled with `HostedServices.enabled = false`. Denoising requires the `BundledSpeech` trait and its model/runtime. A custom chat endpoint supplies neither. The existing `canGenerate` flag helps describe hosted availability, but does not describe each local/remote operation's prerequisites.

**User impact:** A plan can require capabilities that cannot complete in the current build, leading to repeated refusals, poor substitutions, or enabled effects that do not deliver the expected processing.

**Implementation TODO:**

- [ ] Derive a shared capability snapshot from build features, installed model state, provider configuration, and endpoint modalities.
- [ ] Describe availability per operation, with stable reasons such as build exclusion, model unavailable, credential missing, or provider failure.
- [ ] Use this snapshot in UI, tool descriptions/discovery, planning, and execution. Revalidate changed prerequisites at execution time.
- [ ] Capture whether the brief requires stock footage, user footage, or synthesized scenes. Report any material change to that requirement.

**Done when:** Both speech-trait configurations report their actual capabilities. The agent cannot mistake a working chat credential for video-generation access. A disabled capability yields an actionable terminal result before dependent editing work starts.

### VQ-003 — Loudness integration uses the wrong averaging domain

**Owner:** `Audio/Analysis/LoudnessAnalyzer.swift`. **Priority:** P0.

**Code:** [`LoudnessAnalyzer.swift:24–57`](../Sources/CompositorPro/Audio/Analysis/LoudnessAnalyzer.swift#L24); [`EditorViewModel+AudioEnhance.swift:100–116,158–174`](../Sources/CompositorPro/Editor/ViewModel/EditorViewModel+AudioEnhance.swift#L100).

**Technical explanation:** The analyzer K-weights mono samples, converts each block's energy to LUFS, then takes arithmetic means of those logarithmic values for gating and the final result. Integrated loudness must average the retained linear energies and then convert to LUFS. For an illustrative pair of equal-duration retained block levels, `-10` and `-20 LUFS`, direct averaging gives `-15`, while energy averaging gives approximately `-12.60 LUFS`. This illustration is not a measurement of an app render.

The analyzer also uses non-overlapping 400 ms blocks and downmixes channels before measurement. A mono downmix can cancel opposite-phase stereo content. Enhancement measures the whole source file, so two differently trimmed excerpts receive the same source measurement even if their audible levels differ.

**Implementation TODO:**

- [ ] Implement channel-aware BS.1770 measurement using channel-weighted energies, 400 ms blocks with 100 ms hops, and energy-domain absolute/relative gating.
- [ ] Represent silence/insufficient duration explicitly; avoid treating an arbitrary sentinel loudness as a valid normalization target.
- [ ] Measure the intended source span or prepared audible output. Include trim, speed, channel layout, and processing version in analysis identity where they affect the result.
- [ ] Stream analysis with bounded memory, cooperative cancellation, and background execution.

**Done when:** Reference fixtures match an independent trusted meter within a declared tolerance. Tests cover unequal-level sections, silence, short material, stereo channel phase, and distinct excerpts of one source. Existing broad sine-wave checks are supplemented with cases that fail under log-domain averaging.

### VQ-004 — Requested gain increases can have no audible effect

**Owner:** Audio rendering and `Preview/CompositionBuilder.swift`. **Priority:** P0. **Dependency:** VQ-003 for loudness matching.

**Code:** [`CompositionBuilder.swift:622–626`](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L622), [`emitVolumeEnvelope:988–997,1041–1045`](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L988).

**Technical explanation:** A source measured at `-24 LUFS` needs approximately `+8 dB` to target `-16 LUFS`, corresponding to an amplitude multiplier of about `2.512`. The composition path clamps gain and emitted envelope values to `[0, 1]`. For a dry clip at default volume, this becomes `1`, so the requested increase disappears. These clamps protect AVFoundation from invalid ramp values; removing them is not a complete solution.

**User impact:** Stored settings can report a loudness correction while quiet speech remains quiet. Matching multiple takes can fail even when the analyzer returns a plausible number.

**Implementation TODO:**

- [ ] Implement amplification in a sample-processing stage that supports gain above unity, while retaining valid AVFoundation automation ranges.
- [ ] Share that processing stage between preview and export, including nested timelines and denoise wet/dry blending.
- [ ] Define processing order for static gain, manual volume automation, cleanup, fades, and master headroom. Avoid applying the same correction twice.
- [ ] Measure the processed output and report any target limitation caused by headroom or the selected peak policy.

**Done when:** Rendered samples from a quiet test clip increase by the expected gain within tolerance. Fades and attenuation remain correct. Export and preview agree. Existing non-overlapping-ramp protections remain covered.

### VQ-005 — Breath and sibilance regions mix seconds with frames

**Owner:** Shared clip-time mapping and `CompositionBuilder.gainDips`. **Priority:** P0.

**Code:** [`BreathDetector.swift:61–74`](../Sources/CompositorPro/Audio/Analysis/BreathDetector.swift#L61), [`CompositionBuilder.swift:927–934`](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L927), [`Clip.timelineFrame(sourceSeconds:fps:)`](../Sources/CompositorPro/Models/Timeline.swift#L409).

**Technical explanation:** Detectors emit source seconds. `gainDips` compares those numbers directly with `trimStartFrame`, then subtracts the frame count from a seconds value. At 30 fps, a one-second trim is stored as `30`; an event at source seconds `2–2.2` is discarded because the calculated start becomes `30` and the end remains `2.2`.

The shared mapping must implement the following relationship before deliberate frame rounding:

```text
timelinePositionFrames = clip.startFrame
    + (sourceSeconds * fps - clip.trimStartFrame) / clip.speed
```

For `startFrame = 300`, `trimStartFrame = 30`, and `speed = 1`, the source event `2–2.2 s` belongs at frames `330–336`. At speed `2`, it belongs at frames `315–318`.

**Implementation TODO:**

- [ ] Extend the existing source-to-timeline mapping with validated interval conversion, rather than maintaining separate breath, sibilance, beat, and placement arithmetic.
- [ ] Keep exact media time until the frame-domain boundary; define interval-start/end rounding and clip-range intersection once.
- [ ] Handle finite positive speed, nonzero placement, trims, split/nested clips, and end-exclusive boundaries.
- [ ] Fold overlapping dips and fades into the existing non-overlapping envelope planner.

**Done when:** The worked examples pass through the actual region-to-ramp path. Tests cover partial intersections with trims, fractional speed, very short regions, and multiple simultaneous gain operations. No test substitutes precomputed dips for the conversion being tested.

### VQ-006 — Audio analyses delete each other's cache files

**Owner:** `Audio/Analysis` and audio-composition invalidation. **Priority:** P0.

**Code:** [`LoudnessAnalyzer.swift:72–77`](../Sources/CompositorPro/Audio/Analysis/LoudnessAnalyzer.swift#L72), [`BreathDetector.swift:154–159`](../Sources/CompositorPro/Audio/Analysis/BreathDetector.swift#L154), [`DeEsser.swift:147–152`](../Sources/CompositorPro/Audio/Analysis/DeEsser.swift#L147).

**Technical explanation:** All three analyses use the `AudioAnalysis` directory. Their cleanup removes every other file beginning with the same media ID, rather than only stale results of the same analysis kind. The sequence “cache loudness, cache breaths, cache sibilance” can leave only sibilance on disk. Meanwhile, editor sets such as `breathBaked` can still say that breath analysis exists.

**User impact:** Individual effects appear to work, but enabling the combined voice chain can silently remove the evidence required by another stage. Preview rebuilds may use incomplete processing.

**Implementation TODO:**

- [ ] Include analysis kind, source fingerprint, algorithm/model version, and relevant parameters in the key and cleanup scope.
- [ ] Preserve other analysis kinds when replacing one result; install completed cache output atomically.
- [ ] Define one invalidation contract between disk results, editor session state, and cached audio compositions.
- [ ] Make stage failures independent and invalidate prepared compositions when analysis availability changes.

**Done when:** Loudness, breath, and sibilance results coexist after any computation order and after reopen. Recomputing one kind preserves the others. Source replacement and cache clearing invalidate exactly the affected state. Tests use an isolated cache root.

### VQ-007 — Enhancement jobs can return early, commit stale work, or miss export

**Owner:** Editor audio operations, analysis jobs, and export preparation. **Priority:** P0.

**Code:** [`ToolExecutor+VoiceEnhance.swift:64–74`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+VoiceEnhance.swift#L64), [`EditorViewModel+AudioEnhance.swift:106–150,164–197`](../Sources/CompositorPro/Editor/ViewModel/EditorViewModel+AudioEnhance.swift#L106), [`ExportService.swift:565–593`](../Sources/CompositorPro/Export/ExportService.swift#L565).

**Technical explanation:** Enhancement and loudness matching start detached tasks without retaining cancellation handles. Measurement failures are skipped. Completion later finds clips by ID and mutates current state without validating the original source, trim, settings, or timeline identity. The tool returns before that mutation, so its immediate delta can describe no completed work. An undo immediately after the request can target an earlier edit while the enhancement action has not yet entered history.

Export preparation explicitly waits for standalone denoise, while combined enhancement removes the standalone effect and uses its own effect type. Breath/de-ess are read from existing cache. An immediate export therefore has no comprehensive barrier ensuring all requested processing is ready for the exported revision.

**Implementation TODO:**

- [ ] Introduce an owned enhancement job with a stable ID, task handle, immutable input snapshot, stage results, and explicit terminal status.
- [ ] Deduplicate equivalent work; define supersession when the user changes settings. Check cancellation during analysis and before commit.
- [ ] Revalidate project/timeline/clip/source identity, source version, trims, speed, and configuration before applying a result.
- [ ] Return either a completed mutation or a job receipt. Expose terminal failure through UI and MCP rather than relying on log output.
- [ ] Apply the successful requested mutation as one undoable action after preparation. Failed, cancelled, or unchanged requests create no undo entry.
- [ ] Make export await the prepared processing contract for its snapshot, including nested content. Report failed processing explicitly.

**Done when:** Deterministic tests coordinate cancellation, media replacement, timeline switching, changed settings, undo interleaving, and immediate export. No late mutation lands on a changed target; every job reaches an inspectable terminal state.

## 3. P1: build the complete filmmaking workflow

### VQ-008 — Retrieval relevance is not verified shot suitability

**Owner:** Existing `Agent/Retrieval`, stock providers, and source inspection. **Priority:** P1. **Dependency:** VQ-001.

**Code:** [`ShotCandidateBuilder`](../Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift#L240), [`findShotCandidates`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+ShotCandidates.swift#L23), [`VisualSearch`](../Sources/CompositorPro/Search/Query/VisualSearch.swift#L51), [`StockMediaSearch`](../Sources/CompositorPro/MediaSources/StockMedia.swift).

**Technical explanation:** A stock candidate's `usable` state currently establishes properties such as type, URL, and attribution. It does not establish that the video depicts the requested action or location. Library embedding similarity is also a retrieval score, not calibrated proof of suitability. Unified retrieval orders local visual/spoken groups before remote rows; stock aggregation can exhaust the result limit with an earlier provider. These are discovery policies, not final editorial decisions.

**Implementation TODO:**

- [ ] Preserve the current retrieval owner and separate availability, retrieval rank, inspection evidence, and shot acceptance in its results.
- [ ] Retrieve a bounded, diverse shortlist for each shot. Retain provider rank and consider multiple providers before applying the final selection limit.
- [ ] Decode thumbnails and source-frame samples/contact sheets; verify subject, action, usable span, required motion, resolution/crop, and exclusions against the shot requirement.
- [ ] Confirm named locations/entities using provenance as well as appearance. Reject low-confidence matches instead of always choosing the top result.
- [ ] Refine source spans before placement. Coarse indexing samples are not frame-accurate edit boundaries.
- [ ] Retain chosen and rejected candidate IDs/reasons so repairs do not repeat the same poor choice.

**Done when:** A labeled fixture containing irrelevant high-ranking results, misleading titles, wrong locations, and duplicate imagery yields the intended footage or an explicit unresolved shot. Every accepted shot has inspected evidence. Measure selection precision and coverage on the same candidate set before and after changes.

### VQ-009 — The creative brief needs persistent, executable editorial structure

**Owner:** In-progress `EditPlan` and its shared editor operations. **Priority:** P1.

**Code:** [`EditPlan.swift`](../Sources/CompositorPro/Agent/Plans/EditPlan.swift); [`AgentInstructions.swift`](../Sources/CompositorPro/Agent/Tools/AgentInstructions.swift).

**Technical explanation:** The plan currently has sections, shot timing, references, and free-form notes. Professional decisions also depend on required content, narrative purpose, pace, visual continuity, narration, and sound cues. When those constraints exist only in chat, subsequent searches or edits can optimize for a convenient asset instead of the intended film.

**Implementation TODO:**

- [ ] Extend the existing plan with audience, runtime, aspect/delivery format, tone, source/realism requirements, and stable script/shot/cue IDs.
- [ ] Represent each shot's purpose, required subject/action, exclusions, source type, duration, handles, and continuity constraints explicitly.
- [ ] Give sound cues roles such as narration, dialogue, music, ambience, and spot effect, with semantic timing anchors.
- [ ] Keep narration text authoritative in the plan. After synthesis, align actual words/phrases and derive captions and dependent timing from the rendered speech.
- [ ] Make inferred creative decisions visible/editable. A plan revision invalidates dependent selections and reviews where needed.

**Done when:** A short film has a coherent opening, development, and ending; selected footage and sound can be explained against its brief. Script, captions, and timing survive reopening and chat compaction. Changing one section updates only its dependent work.

### VQ-010 — Plan application must commit an actual cut atomically

**Owner:** Editor assembly operations and `ToolExecutor+Plan`. **Priority:** P1. **Dependencies:** VQ-008, VQ-009; current transition work.

**Code:** [`applyPlan`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift#L85), [`addClips`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Clips.swift#L270), [`EditorUndo.perform`](../Sources/CompositorPro/Editor/EditorUndo.swift#L14).

**Technical explanation:** The inspected `apply_plan` reserves readiness and explicitly does not edit the timeline. A finished workflow needs to resolve the plan into placements, trims, linked audio, titles, transitions, and sound cues. `EditorUndo.perform` groups undo registrations; it does not automatically roll back a closure that throws after partial mutation.

**Implementation TODO:**

- [ ] Complete plan application through existing domain operations. Extract shared validation/resolution where necessary so preview, UI, and MCP use identical calculations.
- [ ] Prepare all media and resolve source spans, stable track IDs, settings, overlap rules, transition handles, and linked audio before committing.
- [ ] Carry expected timeline/plan revisions and reject stale preparation. Keep all awaits outside the synchronous undo/commit scope.
- [ ] Ensure commit cannot leave partial state; use an explicit transaction/rollback boundary for any remaining failure-capable step.
- [ ] Return shot-to-clip mappings, mutation deltas, warnings, and no-op state. Mark a plan applied only after its timeline mutation succeeds.

**Done when:** One application produces one coherent undo action; a repeated application is a no-op. Failure leaves the prior timeline intact. Test multi-track placement, linked clips, transitions, nested timelines, reordered tracks, and concurrent UI/MCP edits using independent state readback.

### VQ-011 — Long-running work needs a durable production-run owner

**Owner:** Project-owned agent workflow coordination. **Priority:** P1.

**Code:** [`AgentService.runLoop`](../Sources/CompositorPro/Agent/Chat/AgentService.swift#L542), [`GenerationService.resumePendingGenerations`](../Sources/CompositorPro/Generation/GenerationService.swift#L360), [`AgentInstructions`](../Sources/CompositorPro/Agent/Tools/AgentInstructions.swift).

**Technical explanation:** The chat loop continues when the model requests tools, then ends on a normal response. The instructions correctly say it cannot retrigger itself when generation completes. Existing asset/backend recovery can finish an asset after reopen, but does not restore the editorial intent that should inspect and place that asset. Chat lifetime and production-job lifetime are different.

**Implementation TODO:**

- [ ] Add one project-owned run record containing run ID, plan revision, current stage, completed operation IDs, pending dependency IDs, and terminal outcome.
- [ ] Subscribe to existing import, generation, analysis, and export completion. Resume only the next eligible step instead of busy-polling through model calls.
- [ ] Persist enough state to reconcile completed work after interruption without repeating imports, edits, or paid submissions. Do not automatically resubmit a paid request whose outcome is unknown.
- [ ] Bound preparation concurrency and repair attempts. Retain cancellation handles and reject late commits after cancellation/close.
- [ ] Expose run state and blockers through both UI and MCP; reuse existing package coordination for persisted state.

**Done when:** One request waits for its dependencies and reaches a finished, blocked, failed, or cancelled outcome without a user “continue” message. Restart and duplicate completion events do not duplicate edits. Save As and close preserve the latest admitted state.

### VQ-012 — Audio inspection needs listening and measurement, not only transcription

**Owner:** `Audio/Analysis`, shared mix rendering, and agent audio tools. **Priority:** P1. **Dependencies:** VQ-002, VQ-007.

**Code:** [`ToolExecutor+Media.readAudio`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Media.swift#L365), [`ToolResult.Block`](../Sources/CompositorPro/Agent/Tools/ToolResult.swift#L5), [`ToolExecutor+Drone`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Drone.swift#L15).

**Technical explanation:** Current audio inspection asks a speech recognizer for words. That cannot establish whether a sound is the right door slam, whether music masks a voice, or whether ambience loops cleanly. Tool output supports text and images, but no audio content. A locally synthesized drone supplies a tonal bed, not arbitrary sound design.

**Implementation TODO:**

- [ ] Add source/range and timeline-mix audio analysis with loudness, peaks, speech activity, silence, channel layout, and explicit analysis limits.
- [ ] Render bounded listening previews through the same processing path as playback/export. Associate each preview with source/timeline and processing revisions.
- [ ] Deliver audio to endpoints with verified support; make human audition available and report limitations for other routes. Measurements alone must not certify aesthetic sound quality.
- [ ] Connect planned SFX/ambience cues to retrieval, audition, transient/span selection, placement, fades, and loop treatment as one understandable action.

**Done when:** Music and nonverbal SFX can be inspected without requiring transcription. A cue is audibly appropriate and aligned to its annotated event. An intentional quiet moment remains quiet; missing suitable sound is reported as unresolved work.

### VQ-013 — A dialogue-first mix needs one shared domain operation

**Owner:** Audio mix planning, editor mutations, and rendering. **Priority:** P1. **Dependencies:** VQ-003–007, VQ-009, VQ-012.

**Technical explanation:** Clip volume, fades, VAD, keyframes, and beat detection are useful primitives, but choosing independent dB values is not a mix. Normalizing narration, music, ambience, and SFX to the same loudness destroys their intended hierarchy. Speech-driven music ducking also needs smoothing and ownership rules for existing automation.

**Implementation TODO:**

- [ ] Implement a focused mixing operation that resolves explicit role assignments using stable IDs, prepares dialogue, sets gain staging, and manages music/ambience/SFX relative to speech.
- [ ] Build ducking envelopes from speech activity with lookahead, attack, hold, release, and short-gap merging. Preserve user automation or replace an explicitly owned generated layer.
- [ ] Maintain room tone, phrase endings, and source-audio continuity; time musical changes to meaningful phrases/downbeats when appropriate.
- [ ] Analyze the summed processed mix and enforce the chosen delivery loudness/peak contract. Report measured before/after values and residual problems.
- [ ] Apply mix changes atomically with one undo result and invalidate review when any contributing source or gain changes.

**Done when:** Speech remains intelligible; music does not pump between syllables; ambience is continuous; SFX do not mask dialogue. A selected fixture contract such as `-16 LUFS ±1 LU` and `≤ -1 dBTP` is independently verified on output. Production targets remain brief-specific.

### VQ-014 — Completion needs rendered quality checks and targeted repair

**Owner:** Agent review orchestration and shared rendering/export. **Priority:** P1. **Dependencies:** VQ-001, VQ-010–013.

**Code:** [`ToolExecutor+InspectTimeline.swift:6–10`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+InspectTimeline.swift#L6), [`ToolExecutor+Export.swift`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Export.swift).

**Technical explanation:** Timeline inspection returns up to 12 stills with a 512-pixel longest edge. These establish useful spatial evidence, but can miss one-frame gaps, motion artifacts, illegible small text, abrupt cuts, and audio defects. The model is instructed to spot-check edits, but review is not a durable condition for declaring a production run complete. A queued export is also not a delivered video.

**Implementation TODO:**

- [ ] Render a draft and inspect every selected shot, important boundaries, text/caption states, and mixed audio at appropriate detail.
- [ ] Run deterministic checks for missing media, unexpected black/silence gaps, duration, pending processing, caption bounds, and audio peaks.
- [ ] Review editorial requirements separately: relevance, continuity, pace, readability, realism, and sound motivation. Record uncertainty and human-review needs.
- [ ] Store findings against clip/shot IDs and the reviewed revision. Repair only affected work under a bounded budget, then recheck it.
- [ ] Complete the run only when required checks and export finish; otherwise report specific unresolved work.

**Done when:** Seeded wrong footage, a brief black gap, offscreen captions, clipped narration, and unfinished enhancement are detected. A stale or failed inspection cannot certify the current cut. Human review confirms the creative result.

### VQ-015 — Stock provenance must survive the candidate-to-asset transition

**Owner:** Media manifest/import, project persistence, and export receipts. **Priority:** P1 for production stock workflows.

**Code:** [`MediaManifestEntry`](../Sources/CompositorPro/Models/MediaManifest.swift#L20), [`finishImportedAsset`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Import.swift#L258).

**Technical explanation:** Search candidates carry credits, but the manifest has no permanent stock-provenance record. Import's transient `importInput` is cleared when the asset finishes. Keeping attribution in chat or on an unimported plan candidate does not preserve it when the asset is reused, the plan is deleted, or the project is packaged.

**Implementation TODO:**

- [ ] Persist provider asset ID, landing/source URL, creator, license, attribution, retrieval date, and content identity with the imported asset.
- [ ] Carry that record through candidate selection, import, folder moves, alternate edits, save/reopen, Save As, and packaging.
- [ ] Produce credits for the actual assets used in the exported cut, with source IDs linking back to the project.

**Done when:** Deleting the originating chat/plan does not lose an asset's credits. A packaged project and export receipt retain correct provenance after reopen. Repeated use of one source produces consistent credits.

## 4. P2: expand generation and editorial intelligence

### VQ-016 — Synthesized video and higher-quality speech require real provider integrations

**Owner:** Existing generation submission, catalog, recovery, and speech paths. **Priority:** P2; promote when synthesized footage is mandatory.

**Code:** [`GenerationBackend`](../Sources/CompositorPro/Generation/GenerationBackend.swift#L30), [`GenerationService`](../Sources/CompositorPro/Generation/GenerationService.swift), [`ToolExecutor+Speech`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Speech.swift#L63).

**Technical explanation:** Choosing a powerful reasoning model does not supply video synthesis, a music model, or a natural voice. The current generation backend submits to the account-backed service. A custom chat endpoint is a separate API integration. Realistic multi-shot generation additionally requires persistent character/product/location references and verification of identity/motion continuity.

**Implementation TODO:**

- [ ] Integrate one working generation provider at a time through the existing submit/observe/download/finalize lifecycle.
- [ ] Publish actual modality, reference, duration, resolution, audio, pricing, and recovery capabilities in the model catalog.
- [ ] Carry approved reference assets and consistency constraints across related shots; inspect generated output before using it in the cut.
- [ ] Honor explicitly authorized spending and retain submission IDs before dependent work. Treat unknown submission outcomes as a reconciliation problem, not permission to charge again.
- [ ] Reuse local speech where appropriate; add a verified higher-quality speech route when the brief requires it. Align its actual audio with the canonical script/captions.

**Done when:** A reference-guided short sequence and narration complete with observable cost, terminal state, reusable media IDs, and verified output. Provider failure, cancellation, restart, and unavailable voices produce truthful results.

### VQ-017 — Editorial context and playbooks need versioning and bounded memory

**Owner:** `Agent/Chat`, `Agent/Skills`, request adapters, and diagnostics. **Priority:** P2.

**Code:** [`AgentService.apiMessages`](../Sources/CompositorPro/Agent/Chat/AgentService.swift#L771), [`SkillStore`](../Sources/CompositorPro/Agent/Skills/SkillStore.swift#L171), [`AgentDiagnostics`](../Sources/CompositorPro/Diagnostics/AgentDiagnostics.swift).

**Technical explanation:** Full non-system history is resent on each request, and image mentions are encoded again. Growing tool output and imagery compete with the original brief for endpoint context. Skill content is loaded from the installed/synchronized environment, so different skill versions can also explain different outcomes. These are scalability/reproducibility risks; their quality impact needs measurement.

**Implementation TODO:**

- [ ] Keep the authoritative brief/plan outside chat. Build a bounded revisioned working context containing active IDs, constraints, selected evidence, pending work, and unresolved findings.
- [ ] Compact superseded reads while preserving tool-call/result pairing and required visual evidence. Respect actual endpoint context/output limits and handle truncation through the production-run state.
- [ ] Ship one tested narrated-film playbook first, then expand to interview/product/montage work after each has an evaluated end-to-end path.
- [ ] Version instruction/skill content and explicit user style references. Capture protocol, effective model ID, effort, stop reason, and image-delivery counts in diagnostics.

**Done when:** Long sessions retain the original requirements without unbounded request growth. Repeated runs identify the exact prompt/skill/provider configuration used. Creative-quality and cost/latency comparisons use the same workload.

## 5. Cross-cutting P0: establish quality evidence

### VQ-018 — Add outcome-based regression and filmmaking evaluation

**Owner:** Existing agent, audio, export, and project test suites plus an isolated evaluation harness. **Priority:** P0, started before implementation.

**Technical explanation:** Successful API calls and valid schemas establish transport correctness, not a professional edit. Several current tests verify properties without observing the downstream result: user-image serialization does not test tool-image serialization; safe volume ramps do not prove amplification; broad sine tests do not prove gated integration on changing content.

**Implementation TODO:**

- [ ] Create fixed fixtures for a narrated stock film, supplied-product ad, interview cleanup, and ambience/SFX sequence. Include misleading/distractor assets and negative paths.
- [ ] Test the narrow defect at its actual seam: serialized request, region-to-ramp mapping, independently measured render, cache lifecycle, or async commit.
- [ ] Exercise changed tools through MCP discovery, schema, invocation, terminal jobs, state readback, undo, and saved-project reopen. Keep deterministic tests offline.
- [ ] Compare in-app and external-agent runs using the same effective model, tools, media, instructions, and budget; record differences in available context/tools rather than assuming parity.
- [ ] Score shot relevance, continuity, pacing, captions, intelligibility, sound motivation, task completion, corrective user edits, and cost. Use human review for creative judgments.

**Done when:** Every claimed improvement has a reproducible before/after scenario. A passing tool response is never the sole evidence that the requested edit, processing, or export occurred.

## 6. Implementation contract

- **State:** `EditPlan` owns creative intent; existing timelines own edits; immutable prepared results carry their source, plan, timeline, and processing revisions.
- **Coordination:** One project-owned production-run coordinator references existing jobs and owns dependency progression, cancellation, and durable outcome state.
- **Isolation:** Main actor owns observable state and short commits. File I/O, media decode/render, inference, and heavy transforms cross explicit background boundaries.
- **Mutation:** Resolve and validate before undo grouping; use the same domain helpers for preview, validation, commit, UI, and MCP. Keep commit scopes free of awaits.
- **Staleness:** Revalidate after asynchronous work. Source replacement, timeline changes, superseding settings, undo, close, and Save As can invalidate prepared results.
- **Persistence:** Route live package media installs/removals through `ProjectPackageCoordinator`; stage complete output, serialize matching destinations, clean temporary data, and surface failures.
- **Results:** Distinguish no-op, blocked, running, completed, failed, and cancelled states. Store actual changes and measurements separately from intended settings.

## 7. Recommended work sequence

1. Start **VQ-018** with a small reproducible baseline. Fix **VQ-001** immediately for custom-endpoint reproductions and establish **VQ-002** capability truth.
2. Repair audio math, effective gain, time mapping, cache ownership, and job/export completion: **VQ-003–007**.
3. Integrate the other agent's completed contracts; build verified retrieval, structured intent, assembly, run continuation, and permanent provenance: **VQ-008–011, VQ-015**.
4. Add audio audition, dialogue-first mixing, motivated cues, and rendered review: **VQ-012–014**.
5. Expand generation, speech quality, context handling, and playbooks: **VQ-016–017**, with generation promoted when required by the brief.

**First delivery gate:** One prompt produces a coherent 30-second 16:9 film using an isolated library and one configured stock-video source, narration when requested, appropriate music/ambience/SFX, and a completed H.264 export. Footage is verified, audio processing is measurable, the plan/credits persist, and cancellation plus coherent undo work. Establish this end-to-end result before expanding the feature surface.

## 8. Verification required to close tickets

### Automated commands after implementation

```bash
swift build
swift test --filter 'CustomAgentModelTests|CustomEndpointTransportTests|AgentProviderTests'
swift test --filter 'LoudnessAnalyzerTests|BreathDetectorTests|DeEsserTests|AudioMixRampTests'
swift build --traits BundledSpeech
swift test
```

Extend existing suites and run new focused suites for the changed behavior. Audio/model changes also need applicable trait-enabled tests. Core editor, persistence, concurrency, undo, and shared processing changes require the full suite. Concurrency tests must use deterministic gates rather than sleeps. Performance claims require a fixed before/after workload and measurements.

### Manual verification

- **Setup:** Use a new temporary project, labeled distractor footage, a quiet speech recording with known events, a music bed, and a few SFX. Record endpoint/model and enabled capabilities.
- **Actions:** Request a complete short film; inspect selected footage and captions; audition voice/music/SFX; export and compare the exported sound with preview.
- **Expected:** Correct subjects/actions, coherent pacing, readable text, natural cleanup, intelligible dialogue, appropriate sound, and a completed playable export matching the reviewed revision.
- **Lifecycle:** Cancel during retrieval/analysis/render; use Escape, switch focus/timelines, edit during preparation, undo, save, Save As, close, and reopen. Expect accurate outcomes, no stale commits, no duplicate work, and preserved project state.
- **Failures:** Exercise empty/missing media, absent keys/models/voices, no relevant footage, corrupt downloads, processing failure, and unavailable provider modalities. Expect specific blockers rather than success-shaped responses.

UI and creative quality require human confirmation.

### Status of this document

Prepared from source inspection and a fresh check of concurrent changes. No implementation, build, live model call, audio/video render, or MCP runtime test was performed while writing this backlog. Technical examples illustrate the identified mechanisms; acceptance tests describe work still required.
