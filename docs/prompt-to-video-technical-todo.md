# Prompt-to-video quality: technical TODO

Reviewed: 2026-10-01. Base commit: `75ef7d8` on `main`, with concurrent uncommitted work.

## Assessment

The repository already has substantial editing capability. The biggest improvements are in the agent's access to evidence, audio correctness, and orchestration of a complete filmmaking workflow.

Several concrete implementation problems can undermine even a strong model:

1. **Custom endpoints lose inspected images.** The Chat Completions adapter discards image blocks inside tool results. A model using that route receives metadata from `inspect_media` and `inspect_timeline`, but not their pictures.
2. **Generation availability differs from chat-model availability.** Hosted image, video, and audio generation is explicitly disabled in this checkout. A working chat API key does not enable those services. Denoising also depends on the `BundledSpeech` build trait.
3. **Audio controls can overstate their result.** Positive gain is clamped to unity in the composition path; loudness integration averages logarithmic values; breath/sibilance placement mixes source seconds with frame counts; analysis caches delete one another.
4. **Asynchronous enhancement has weak completion semantics.** Tools return before enhancement commits, background errors can be skipped, and export does not consistently wait for the full enhancement chain.
5. **Retrieval supplies candidates, rather than verified editorial selections.** Search results need content inspection, shot-specific rejection criteria, and sequence-level judgment before placement.
6. **The agent lacks a durable end-to-end production loop.** Existing inspection, mutation, generation, and export tools need to participate in a persistent plan with quality checks and resumable work.

These are source-level findings. The user's failing prompt, selected endpoint, generated project, and comparison run were not supplied, so their relative contribution to that particular failure remains unmeasured. No comparison against Cursor or Claude Code was run. Compare the same effective model, assets, instructions, available tools, and budget before attributing differences to model quality.

### Existing foundation to reuse

- Shared in-app/MCP execution: [`ToolExecutor`](../Sources/CompositorPro/Agent/Tools/ToolExecutor.swift#L6) and [`MCPService`](../Sources/CompositorPro/Agent/MCP/MCPService.swift#L79).
- Visual and transcript search: [`VisualSearch`](../Sources/CompositorPro/Search/Query/VisualSearch.swift#L14), `SearchIndexCoordinator`, and `search_media`.
- Real source/composited images: [`inspect_media`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Media.swift#L184) and [`inspect_timeline`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+InspectTimeline.swift#L13).
- Batch placement, ripple editing, linked clips, layouts, keyframes, text, captions, color, and effects. [`add_clips`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Clips.swift#L270) already validates a batch and uses [`EditorUndo`](../Sources/CompositorPro/Editor/EditorUndo.swift#L14).
- Voice cleanup, loudness analysis, VAD, beat detection, system-voice speech synthesis, and tonal drone synthesis.
- Generation placeholders and backend-job recovery: [`GenerationService.resumePendingGenerations`](../Sources/CompositorPro/Generation/GenerationService.swift#L360).
- Queued exports with progress, cancellation, and terminal results: [`manage_exports`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Export.swift#L4).
- Coordinated project-package mutations: [`ProjectPackageCoordinator`](../Sources/CompositorPro/Project/ProjectPackageCoordinator.swift#L31).

### Concurrent-work handoff

Another agent was actively changing these areas during inspection:

- `Agent/Plans/EditPlan.swift`, `ToolExecutor+Plan.swift`, `EditorViewModel+EditPlans.swift`, and project save/load integration.
- `Agent/Retrieval/ShotCandidates.swift` and the new `ToolExecutor+ShotCandidates.swift` / `find_shot_candidates` tool.
- Stock-provider plumbing, Pixabay, credentials, settings, instructions, and associated tests.
- Final status also showed changes to `Models/Timeline.swift` and a new `Models/TimelineTransition.swift`; coordinate transition/assembly work with that owner.

Treat those as in-progress foundations. Re-read their final contracts before implementation; source line numbers may move during concurrent edits. In the inspected version, `apply_plan` validates/reserves readiness and explicitly returns `applied: false`; candidate retrieval combines library evidence and stock catalog rows without inspecting remote media content. Neither observation is a claim that the other agent has finished its work.

All backlog checkboxes below are future work, including verification. This investigation added only this document.

## P0 — Make existing capabilities trustworthy

### P0-00 — Establish a reproducible quality baseline

- [ ] Capture a small fixture set covering prompt-to-stock-video, product footage selection, interview cleanup, and ambience/SFX editing.
- [ ] Record effective wire model ID, endpoint protocol, reasoning setting, instruction/skill versions, enabled capabilities, asset IDs, and output timeline revision.
- [ ] Record candidate selections, rejection reasons, actual inspection delivery, terminal job states, and exported output measurements. Keep credentials and production user content out of fixtures/logs.
- [ ] Run the same fixtures through the in-app agent and an external agent using the same MCP tools. Record extra tools/context separately.

**Ownership:** `Tests/CompositorProTests/Agent`, audio/export fixtures, and `Diagnostics/AgentDiagnostics.swift`.

**Acceptance:** Every reported failure can be assigned to transport, retrieval, planning, execution, audio processing, or review using a replayable artifact. Track visual relevance and human edit quality alongside tool success rates. Begin this before changing the workflow; expand it as capabilities land.

### P0-01 — Preserve multimodal inspection through custom endpoints

**Evidence:** [`OpenAIChatCompletionsProvider.swift:76–87,129–135`](../Sources/CompositorPro/Agent/Clients/OpenAIChatCompletionsProvider.swift#L76) serializes tool results through `toolResultText`, which retains only `.text`. Direct Anthropic and OpenAI Responses adapters preserve tool-result images. [`CustomAgentModelTests.swift:78–127`](../Tests/CompositorProTests/Agent/CustomAgentModelTests.swift#L78) tests a user-attached image and a text-only tool result, leaving this path uncovered.

- [ ] Preserve inspection images using the selected endpoint's supported multimodal message format, with explicit tool-call, media, and frame associations.
- [ ] Represent vision support explicitly. An unsupported route must report that visual inspection is unavailable instead of silently converting it to text.
- [ ] Cover mixed text/images, image-only results, multiple tool calls, history replay, and provider errors.

**Ownership:** `Agent/Clients`; retain `ToolResult` as the shared tool-output representation.

**Acceptance:** A loopback transport test receives the actual image payload returned by an inspection tool. A controlled image-recognition scenario works with misleading filenames. Existing text-only tool calls continue to work. This is the first fix when reproducing through a custom endpoint.

### P0-02 — Expose capabilities from actual runtime configuration

**Evidence:** [`HostedServices.swift:14`](../Sources/CompositorPro/Backend/HostedServices.swift#L14) sets `enabled = false`; [`ToolExecutor+Generate.swift:35–42`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Generate.swift#L35) refuses generation. [`AudioEnhancer.swift:21–40`](../Sources/CompositorPro/Audio/AudioEnhancer.swift#L21) throws without `BUNDLED_SPEECH`; [`Package.swift:12–15,50–64`](../Package.swift#L12) makes that trait optional.

- [ ] Expose structured availability for visual inspection, stock video, local speech, denoising, music/SFX generation, and image/video generation through existing discovery/context surfaces.
- [ ] Distinguish build exclusion, missing model download, missing provider credential, unsupported modality, and temporary provider failure.
- [ ] Use the same capability checks in UI, tool discovery/descriptions, and execution. Generate recommendations from those checks.
- [ ] Resolve whether the brief requires existing footage or newly synthesized scenes before promising an outcome. Report a material substitution explicitly.

**Acceptance:** A plain `swift build` cannot promise working denoising that later fails silently. A chat credential cannot be mistaken for a generation credential. Disabled hosted services produce an accurate available workflow. Verify both build-trait configurations and actual model readiness.

### P0-03 — Correct loudness measurement and implement effective positive gain

**Evidence:** [`LoudnessAnalyzer.swift:24–57`](../Sources/CompositorPro/Audio/Analysis/LoudnessAnalyzer.swift#L24) downmixes to mono, uses non-overlapping 400 ms blocks, and averages LUFS values directly. [`EditorViewModel+AudioEnhance.swift:100–116,158–174`](../Sources/CompositorPro/Editor/ViewModel/EditorViewModel+AudioEnhance.swift#L100) measures the whole source rather than the edited span. [`CompositionBuilder.swift:622–626,988–997,1041–1045`](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L622) clamps gain/envelopes to `[0, 1]`; a default-volume dry clip cannot receive a requested positive boost.

- [ ] Implement validated channel-aware BS.1770 loudness measurement: energy-domain integration, overlapping analysis blocks, correct gating, and explicit silence/short-input behavior.
- [ ] Measure the intended edited audio, including trim, speed, applied processing, and current gain, at the appropriate stage.
- [ ] Add a gain-processing path capable of amplification, shared by preview and export. Preserve AVFoundation's valid ramp ranges rather than removing the clamp and reviving framework exceptions.
- [ ] Add headroom/true-peak handling and measured post-processing results. Report when a requested target cannot be reached safely.

**Acceptance:** Reference mono/stereo fixtures match a trusted independent loudness meter within a declared tolerance. Unequal-level segments, channel cancellation, trims, silence, and short clips are covered. A quiet clip actually becomes louder by the requested amount in rendered samples, not merely in stored properties.

### P0-04 — Fix breath/sibilance source-time mapping

**Evidence:** [`BreathDetector.swift:61–74`](../Sources/CompositorPro/Audio/Analysis/BreathDetector.swift#L61) produces seconds. [`CompositionBuilder.gainDips:927–934`](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L927) compares/subtracts those values against `trimStartFrame` and `sourceFramesConsumed`. For a 30 fps clip trimmed by 30 frames, a breath at source seconds 2–2.2 is discarded by the comparison against `30`.

- [ ] Route analysis regions through one source-to-timeline conversion that handles trim, speed, placement, clipping, and half-open end boundaries.
- [ ] Reuse/extend [`Clip.timelineFrame(sourceSeconds:fps:)`](../Sources/CompositorPro/Models/Timeline.swift#L407) for the shared timing contract; define interval-end rounding explicitly.
- [ ] Preserve contiguous, non-overlapping AVFoundation ramps when several attenuations and fades intersect.

**Acceptance:** With a one-second source trim, the two-second source event attenuates one second into the clip. Test fractional speed, nonzero timeline start, split clips, nested timelines, overlapping events, and events touching either trim boundary through rendered audio or the real region-to-ramp path.

### P0-05 — Keep audio analyses and composition caches consistent

**Evidence:** Loudness, breath, and de-ess analyses share `DiskCache(named: "AudioAnalysis")`. Each stale-cache cleanup deletes every other file with the same media-ID prefix: [`LoudnessAnalyzer.swift:72–77`](../Sources/CompositorPro/Audio/Analysis/LoudnessAnalyzer.swift#L72), [`BreathDetector.swift:154–159`](../Sources/CompositorPro/Audio/Analysis/BreathDetector.swift#L154), [`DeEsser.swift:147–152`](../Sources/CompositorPro/Audio/Analysis/DeEsser.swift#L147). Computing de-ess after breath can delete the breath result while editor session state still marks it baked.

- [ ] Scope cache invalidation to analysis kind, source identity/version, algorithm version, and analysis parameters.
- [ ] Keep successful stage results independent; one stage's failure must not mark all stages failed.
- [ ] Invalidate/rebuild cached audio compositions when a required result becomes available or changes. Ensure lightweight preview refresh uses the same analysis snapshot as a full rebuild.
- [ ] Bound retained analyses and perform disk work off-main.

**Acceptance:** Loudness, breath, and sibilance results coexist for one source and survive reload. Recomputing one stage preserves the other stages. Clearing caches or replacing the source invalidates the matching session state. Preview and export apply the same available processing.

### P0-06 — Make enhancement completion, cancellation, undo, and export reliable

**Evidence:** [`ToolExecutor+VoiceEnhance.swift:64–74,96–105`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+VoiceEnhance.swift#L64) returns a mutation receipt before background work completes. [`EditorViewModel+AudioEnhance.swift:106–150,164–197`](../Sources/CompositorPro/Editor/ViewModel/EditorViewModel+AudioEnhance.swift#L106) starts unstored detached tasks, skips measurement errors, then commits by clip ID without rechecking source/timeline configuration. [`ExportService.swift:565–593`](../Sources/CompositorPro/Export/ExportService.swift#L565) prepares standalone denoise, while other enhancement stages are read from whatever cache exists.

- [ ] Give each enhancement request an owned task and inspectable terminal result. Report queued/running/failed/cancelled/completed accurately, with stage-specific errors and actual changed IDs.
- [ ] Snapshot project/timeline identity, clip/media identity, source version, trims, speed, and settings; revalidate before committing after each asynchronous phase.
- [ ] Coalesce identical requests and define replacement behavior for changed requests. Cancellation/close must prevent late commits.
- [ ] Create one meaningful undo action after successful preparation; an immediate receipt must not imply the enhancement has already happened.
- [ ] Have export consume a prepared processing snapshot for all enabled stages, including nested content. Explicitly report incomplete or failed requested enhancement.

**Acceptance:** Deterministic tests cover cancellation, source replacement, timeline switching, undo interleaving, repeated requests, missing models, and export immediately after `enhance_voice`. Failures are visible through MCP and UI; no stale processing lands later on a changed clip.

## P1 — Complete a professional stock-footage workflow

### P1-01 — Extend the in-progress plan into an editorial brief and shot/sound plan

**Evidence:** The current [`EditPlan`](../Sources/CompositorPro/Agent/Plans/EditPlan.swift) provides sections, shot timing, references, notes, and status. Its shot schema does not yet express structured visual requirements, narration, or sound cues.

- [ ] Extend that owner with intended audience, duration, format, tone, realism/source requirements, language, and delivery constraints. Record inferred choices so they remain editable.
- [ ] Give each shot a narrative purpose, required subject/action/location, shot size/motion, acceptable source types, exclusions, target duration, and source handles.
- [ ] Add script segments and sound cues with stable IDs, roles, and timing dependencies. Keep one authoritative script/plan.
- [ ] Define hook/development/payoff, coverage variety, continuity, and pacing for the chosen brief. Ask a focused question only when missing information materially changes the film.

**Acceptance:** A 30-second brief yields a reviewable, duration-consistent plan with an explicit visual and sound purpose for each section. Reopening the project preserves it. Critical requirements survive chat-history compaction.

**Dependency:** Coordinate with the current plan/persistence owner before changing its schema.

### P1-02 — Retrieve, inspect, reject, then select footage

**Evidence:** [`find_stock_media`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+StockMedia.swift#L67) returns JSON candidates; thumbnail URLs are not delivered image content. [`StockMediaSearch`](../Sources/CompositorPro/MediaSources/StockMedia.swift) concatenates provider results before limiting them. [`VisualSearch.swift:51–57`](../Sources/CompositorPro/Search/Query/VisualSearch.swift#L51) ranks embeddings, with a global floor from `SearchIndexConfig`; those scores do not prove shot suitability. The in-progress [`find_shot_candidates`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+ShotCandidates.swift) unifies retrieval but still returns candidates.

- [ ] Build on `find_shot_candidates` and `ShotCandidateBuilder`; retain separate visual, spoken, and catalog evidence.
- [ ] Expand each shot requirement into a small bounded set of queries. Request video explicitly for motion-led shots and report unavailable coverage instead of silently selecting stills.
- [ ] Retrieve a diverse shortlist before limiting final selections; preserve provider relevance and prevent the first provider from exhausting the budget.
- [ ] Inspect candidate thumbnails and representative source frames/contact sheets. A URL or matching title is insufficient evidence of subject, action, authenticity, or useful timing.
- [ ] Reject wrong subject/location, wrong action, inappropriate generated/illustrated material, insufficient usable duration, unsuitable crop/resolution, and duplicates. Verify named locations/entities with provenance as well as appearance.
- [ ] Store chosen source span, evidence, rejection reasons, and unresolved requirements against the shot ID. Calibrate acceptance on labeled examples; allow “no suitable candidate.”
- [ ] Refine source boundaries before editing. [`FrameSampler`](../Sources/CompositorPro/Search/Indexing/FrameSampler.swift#L10) uses coarse 2-second sampling, doubled for high-resolution media; indexing boundaries are discovery hints.

**Acceptance:** A distractor-rich fixture returns the correct subject despite misleading names/tags. Every automatically selected shot has inspected evidence. Motion-led briefs remain motion-led; incomplete indexing, missing keys, and zero relevant results are distinguishable. Measure selection quality before/after on identical candidate sets.

**Dependencies:** P0-01; current retrieval/provider work.

### P1-03 — Turn a ready plan into one validated, undoable assembly

**Evidence:** [`applyPlan`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift#L85) currently reserves readiness. Placement/time conversion remains in the existing editor/tool operations; there is no completed plan-to-cut operation in the inspected plan implementation.

- [ ] Implement assembly through shared editor-domain placement, linking, ripple, layout, text, and settings operations. Move reusable placement validation into its owning domain where necessary.
- [ ] Resolve every asset, track, source span, linked audio policy, overlap, and timeline setting before mutation. Preview and commit must consume the same resolved operation.
- [ ] Validate timeline identity/revision before commit, including changes made by UI or another MCP session. Preserve explicit user edits when revising a subset of shots.
- [ ] Commit one coherent cut as one `EditorUndo` action, with shot-to-clip IDs, changed/no-op state, and actionable blockers in its receipt.
- [ ] Map beats and sound cues through trim/speed/placement in application code. `detect_beats` currently returns source seconds; the model should not reconstruct timing arithmetic.

**Acceptance:** Failed preparation leaves the timeline untouched. Reapplying the same completed operation is a no-op. One undo restores exact pre-assembly state. Test linked clips, overlapping footage, reordered tracks, nested timelines, missing media, changed settings, and concurrent edits through MCP.

**Dependencies:** P1-01, P1-02; current plan implementation.

### P1-04 — Continue multi-step work when media becomes ready

**Evidence:** [`AgentService.runLoop`](../Sources/CompositorPro/Agent/Chat/AgentService.swift#L542) continues on tool-use responses and otherwise ends. [`AgentInstructions`](../Sources/CompositorPro/Agent/Tools/AgentInstructions.swift) explicitly says a turn cannot retrigger itself after generation. Asset/backend recovery already exists, but does not resume a dependent editorial plan.

- [ ] Add one project-owned production-run coordinator with a persisted run ID, plan revision, completed steps, pending dependencies, and terminal result.
- [ ] Reuse import placeholders, `GenerationService`, analysis services, and `ExportQueue`; subscribe to their completion rather than creating a second implementation or busy-polling the model.
- [ ] Resume only the next eligible step. Use idempotency keys and persisted receipts to avoid duplicate imports, placements, or paid submissions after retries/restart.
- [ ] Define cancellation, blocked dependency, partial preparation, retry, close, and Save As behavior. Bound network, decoding, and inference independently.
- [ ] Keep task state inspectable from both in-app chat and MCP.

**Acceptance:** One request can wait for footage, finish assembly, mix, review, and reach a terminal result without asking the user to type “continue.” Cancellation prevents future automatic edits. Reopening resumes or reports blocked work accurately; it never charges or assembles twice.

### P1-05 — Add audio inspection of sources and the rendered mix

**Evidence:** [`ToolExecutor+Media.readAudio`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Media.swift#L365) performs transcription. [`ToolResult.Block`](../Sources/CompositorPro/Agent/Tools/ToolResult.swift#L5) supports text/images only. The current agent cannot audition an SFX or assess a mix from an audio tool response.

- [ ] Add a filmmaker-facing audio-analysis operation for source spans and timeline ranges: measured loudness, peaks/true peak, silence, speech activity, channel layout, and relevant quality warnings.
- [ ] Analyze a mix rendered through the shared playback/export processing path, with a timeline/processing revision in the result.
- [ ] Provide bounded listening previews for routes with verified audio support; use explicit capability status and human audition for unsupported routes.
- [ ] Treat music/ambience/SFX as audio content, rather than forcing all audio inspection through speech recognition.

**Acceptance:** The agent can distinguish silent material, clipped speech, music, and nonverbal SFX using actual evidence. A loud music bed masking narration is detected on the mixed output. Results become stale when the mix changes and cannot certify a newer revision.

### P1-06 — Provide a dialogue-first mixing operation

**Evidence:** Clip gain/fades/keyframes, VAD, beats, and cleanup already exist. Tool contracts do not expose an integrated dialogue/music/ambience/SFX mix or automatic speech-driven ducking.

- [ ] Define explicit audio roles tied to stable clip/track IDs. Voice, music, ambience, and effects need different level and processing policies.
- [ ] Implement `mix_audio` or an equivalently focused domain operation: prepare voice, set gain staging, duck music during speech, smooth short pauses, and apply intentional head/tail fades.
- [ ] Use VAD/transcript timing for lookahead/attack/hold/release envelopes; preserve manual automation with an explicit ownership/replacement rule.
- [ ] Measure the combined output and apply a selected delivery loudness/true-peak target. Verify headroom after summing stems.
- [ ] Preserve natural breaths/room tone and support J/L audio continuity. Use musical phrases/downbeats where motivated rather than cutting every beat.

**Acceptance:** Narration remains intelligible, music recovers between phrases without pumping, ambience stays continuous, and the output meets the selected measured target. An example test preset may require `-16 LUFS ±1 LU` and `≤ -1 dBTP`; that is a fixture contract, not a universal target for every film. One mix operation has one undoable result.

**Dependencies:** P0 audio repairs, P1-05.

### P1-07 — Design and place motivated sound cues

**Evidence:** Openverse offers audio candidates; [`generate_drone`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Drone.swift#L15) synthesizes a tonal bed. General generated SFX currently depend on disabled hosted audio generation. These capabilities need editorial cue selection and audition.

- [ ] Use plan cues such as rain ambience, footsteps, a door close, or a transition accent, with an audible purpose and explicit timing anchor.
- [ ] Retrieve/audition candidates and select usable spans/transients. Account for attack, tail, room character, and repeated sounds.
- [ ] Place cues on role-specific tracks using shared mutations; support loop seams/crossfades for sustained ambience and keep dialogue clear.
- [ ] Set levels from the mix context, not a universal fixed dB value. Preserve requested quiet moments and avoid adding an effect at every cut.

**Acceptance:** In a supplied door-close shot, the transient lands on the annotated action within the fixture tolerance; ambience has no audible seam; effects do not cover speech. Missing suitable audio produces an explicit gap in the plan rather than a claimed completed sound design.

**Dependencies:** P1-01, P1-05, P1-06; stock retrieval work.

### P1-08 — Require rendered review and bounded repair before declaring completion

**Evidence:** [`inspect_timeline`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+InspectTimeline.swift#L6) returns at most 12 stills, with a 512-pixel longest edge. This helps with composition, but cannot alone establish motion continuity, audio quality, or delivery readiness. Review is currently an instruction to the model rather than a completion condition.

- [ ] Render a draft through the real composition/export path and inspect each selected shot, important cuts, titles/captions, and the mixed audio.
- [ ] Add deterministic checks for missing media, unintended gaps/black frames, unsupported processing, duration, caption bounds, clipping, and unresolved jobs.
- [ ] Add editorial review against the brief: subject relevance, continuity, pacing, shot variety, readability, realism, and sound motivation. Preserve uncertainty for judgments automation cannot establish.
- [ ] Store findings with shot/clip IDs and timeline revision. Repair specific failures under a bounded iteration/cost budget, then recheck affected output.
- [ ] Declare completion only for a verified revision and completed export; expose unresolved findings or waiting/failed export state accurately.

**Acceptance:** Intentionally wrong footage, a black gap, hidden title, clipped narration, and unfinished enhancement are caught in fixtures. Inspection failure cannot produce a passing report. Human review confirms the intended creative result.

## P2 — Broaden creative range after the first workflow works

### P2-01 — Connect a real generation provider for synthesized scenes and sound

- [ ] Add one working image/video/audio provider integration at a time at the existing generation submission/observation/import boundary. [`GenerationBackend`](../Sources/CompositorPro/Generation/GenerationBackend.swift#L30) currently calls the account-backed Convex service; a chat endpoint is a different integration.
- [ ] Expose actual input modalities, duration/resolution limits, reference support, sound support, pricing, and job status in the model catalog.
- [ ] Carry approved character/product/location references across related shots; track generated-shot consistency in the plan and review it against rendered output.
- [ ] Apply explicitly authorized generation budgets, cancellation, durable job recovery, and duplicate-submission protection.

**Acceptance:** A short reference-guided generated sequence completes through the existing project pipeline with measurable cost and observable failure/recovery. Inspect identity, motion, and audio quality. Keep this on the critical path if the product requirement is fully synthesized footage; stock assembly alone does not fulfill that requirement.

### P2-02 — Drive narration, captions, and shot timing from one timed script

- [ ] Extend the plan's script segments with voice/language/delivery choices and pronunciation controls supported by the selected speech engine.
- [ ] Reuse `SpeechSynthesizer` and `generate_speech`; align the actual rendered speech, then derive captions and shot timing from its measured word/phrase timing.
- [ ] Revise script length or explicitly authorized speaking rate when duration does not fit. Preserve natural phrasing.
- [ ] Add a higher-quality speech provider only through a verified capability path when the installed system voices do not meet the brief.

**Acceptance:** Spoken words, captions, and the canonical script agree; captions track the actual generated audio; language/voice mismatch is visible; changing narration invalidates dependent timing and the mix review.

### P2-03 — Ship tested filmmaking playbooks and reusable style references

**Evidence:** [`SkillStore`](../Sources/CompositorPro/Agent/Skills/SkillStore.swift#L171) supports automatically synchronized skills, with instructions loaded on demand. Their installed versions/content are part of the runtime environment, so their presence alone does not establish a reproducible filmmaking baseline.

- [ ] Start with one tested playbook for a narrated B-roll film, then add interview, product, and montage workflows after each works end to end.
- [ ] Encode shot-selection judgment, continuity, pacing, restrained transitions, title hierarchy, color consistency, and role-specific audio treatment alongside tool procedures.
- [ ] Keep a versioned minimal baseline available offline using shared resource lookup. Preserve installed/user-authored skill ownership.
- [ ] Store reusable user style preferences/reference selections explicitly, separate from one project's transient chat.

**Acceptance:** The same fixture and pinned playbook produce a coherent cut across supported model routes. Improvements are demonstrated by blind human comparison. Recipes adapt to the supplied footage rather than applying identical effects/cadence to every film.

### P2-04 — Bound context and diagnose provider behavior

**Evidence:** [`AgentService.apiMessages`](../Sources/CompositorPro/Agent/Chat/AgentService.swift#L771) resends all non-system history and re-inlines image mentions. The run loop only continues automatically for `.toolUse`; output truncation is not a durable production continuation. Current diagnostics mainly record model/tool transport activity.

- [ ] Budget requests using actual endpoint context/output limits and modality support. Record token usage, image delivery counts, stop reason, and selected capability/skill versions.
- [ ] Compact superseded reads into a revisioned working summary while preserving the authoritative plan, constraints, unresolved work, current IDs, and tool-call/result pairing.
- [ ] Retain bounded inspection artifacts with explicit source/timeline invalidation rather than repeatedly attaching every historical image.
- [ ] Handle output truncation, transient transport failure, and repeated non-progress through the production-run state, with bounded recovery.

**Acceptance:** A long multi-shot session completes within the configured context budget and retains its original brief. No repeated side effects occur after retries. Compare cost, latency, and output quality under the same workload before claiming improvement.

### P2-05 — Preserve source provenance independently of chat and plans

**Evidence:** [`MediaManifestEntry`](../Sources/CompositorPro/Models/MediaManifest.swift#L20) has no stock-license/attribution record. [`finishImportedAsset`](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Import.swift#L258) clears transient `importInput`. The current stock workflow asks the model to retain attribution in conversation; plan candidate provenance alone does not establish permanent asset provenance.

- [ ] Persist provider asset ID, landing/source URL, creator, license/attribution, retrieval date, and content identity with imported stock assets.
- [ ] Keep provenance when a candidate becomes a `mediaRef`, moves folders, is reused in a different plan, or survives deletion of the originating chat/plan.
- [ ] Include used-source credits/provenance in project packaging and an export receipt or credits document.
- [ ] Route installs and saves through `ProjectPackageCoordinator` and existing manifest persistence.

**Acceptance:** Import → placement → save → reopen → Save As → package/export retains credits for every used stock asset. Repeated import of the same identified content does not create contradictory provenance.

## Ownership and implementation boundaries

- **Authoritative creative state:** The existing editor-owned `EditPlan`; immutable snapshots go to retrieval, analysis, and planning work. Derived candidates/review reports carry plan/source/timeline revisions.
- **Authoritative edit state:** Existing editor timelines and `EditorUndo`. UI, in-app agent, and MCP call the same domain operations.
- **Long-running work:** One project-owned production-run coordinator references existing import/generation/analysis/export jobs. It owns cancellation and persistence of dependency state.
- **Audio:** Analysis and DSP live under `Audio`; preparation and mutation use the editor's audio operations. Preview, analysis, and export consume the same prepared processing contract.
- **Isolation:** UI state and commit coordination remain main-actor owned. Network, filesystem access, media decode/render, and inference execute behind explicit background boundaries with bounded work.
- **Commit invariant:** Prepared results commit only to the project, timeline, source, and revision they were prepared for. Revalidate after asynchronous work; reject stale results before undo grouping.
- **Package invariant:** Stage complete output, use coordinated installation, clean temporary files, and preserve successful state through save, Save As, close, and cancellation.

## Delivery order and stop conditions

1. **Capture P0-00 baseline, then repair P0-01–06.** Gate: inspection reaches the model; requested audio processing is audible, correct, cancellable, and honestly reported.
2. **Integrate the other agent's final plan/retrieval contracts; implement P1-01–04.** Gate: one request produces a verified-footage rough cut, with stable shot IDs, resumable dependencies, and exact undo.
3. **Implement P1-05–08.** Gate: that same cut has intelligible narration, motivated ambience/SFX, measured mix quality, and a reviewed completed export.
4. **Expand P2 capabilities against the same evaluation set.** Prioritize generation earlier when new synthetic scenes are mandatory. Land asset provenance with the first production stock-import workflow.

**First end-to-end slice:** A 30-second, 16:9 narrated film from an isolated library plus one configured stock-video source, with roughly 6–8 intentional shots, captions when requested, one music bed, appropriate ambience/SFX, and an H.264 export. It must finish from one request, reject irrelevant footage, preserve its plan/credits, and support cancellation and coherent undo. Choose shot count from the brief rather than hardcoding this example into production logic.

## Verification plan for implementation

### Automated gates

Run relevant focused suites after changes; extend them with the regressions above. These commands are planned verification, not results of this investigation:

```bash
swift build
swift test --filter 'CustomAgentModelTests|CustomEndpointTransportTests|AgentProviderTests'
swift test --filter 'LoudnessAnalyzerTests|BreathDetectorTests|DeEsserTests|AudioMixRampTests'
swift build --traits BundledSpeech
swift test
```

- Add independent rendered-sample checks for gain, loudness, trim/speed mapping, processing completion, and preview/export parity. Existing property/schema tests alone cannot establish the audible result.
- Test new tools through MCP discovery/schema/call boundaries, then independently read timeline/project state, exercise undo, and reopen saved packages. Include no-op, invalid arguments, stale revision, async failure, and cancellation.
- Keep deterministic unit/transport tests offline with injected providers and unique temporary projects. Use gates/continuations for concurrency tests.
- Run real-provider quality evaluation separately, recording provider/model versions and cost. Score subject/action relevance, continuity, pacing, title/caption readability, intelligibility, and motivated sound design through human review.
- For larger workloads, measure retrieval latency, memory, main-thread stalls, and rendering responsiveness with a fixed representative project before/after. Increased tool count or passing API calls is not a quality metric.

### Manual UI and end-to-end scenarios

1. **Visual evidence:** Open a temporary project containing correctly and misleadingly named distractor footage. Request a specific visible action through direct and custom routes. Expect inspected content to determine selection; inspect contact sheets and the resulting cut.
2. **Professional cut:** Supply the 30-second brief above. Expect purposeful shot progression, consistent framing/color/titles, readable captions, appropriate music/ambience, and a completed playable export.
3. **Audio correctness:** Use quiet dialogue containing known breaths/sibilants, trim its start, change speed, enhance, and add music/SFX. Expect correctly timed cleanup, measurable gain, intelligibility, natural pauses, and matching preview/export audio. Audition on headphones and speakers.
4. **Lifecycle:** Cancel during retrieval, analysis, and render; press Escape; switch timelines/focus; edit while preparation is running; undo; save, Save As, close, and reopen. Expect accurate status, no late edits, preserved user changes, and no duplicated assets/jobs.
5. **Unavailable/empty states:** Exercise empty libraries, incomplete indexing, missing keys/models, unvoiced language, no relevant footage, corrupt media, and failed downloads. Expect actionable blockers and truthful partial results.

UI/creative quality is accepted only after human verification.

## Investigation verification record

- Read source paths for chat routing, provider payloads, tools/MCP, concurrent plans/retrieval, stock providers/import, audio analysis/processing, composition, generation recovery, undo, export, and persistence.
- Inspected `git status --short --branch`, `git diff --stat`, focused diffs, and `git log --oneline -15`; rechecked status as new concurrent files appeared.
- Inspected existing test coverage, including the multimodal adapter coverage gap and audio ramp/loudness tests.
- Checked document whitespace with `git diff --no-index --check -- /dev/null docs/prompt-to-video-technical-todo.md`; no errors reported.
- No source implementation, build, unit tests, live provider calls, app launch, MCP runtime, or media render was performed for this documentation-only investigation. Findings require the targeted regression and end-to-end verification described above before claiming the improvements are delivered.
