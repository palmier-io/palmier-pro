# Professional video editing without paid services

Audit date: 2026-11-06. Source baseline: `34cd0d0` plus the existing local working changes. Recommendations only; no application implementation changed during this audit.

## Recommendation

Build the first dependable workflow around **user footage + one brief → a finished 30–60-second video**. Use local analysis, evidence-backed shot selection, consistent editorial recipes, finished-audio processing, and a render–review–repair loop.

Compositor Pro already has much of the editing machinery. The largest gains come from making that machinery reliable and coordinating it through completion. Adding more effects or stronger prompts alone will not fix the current audio, continuation, and verification gaps.

This can avoid paid media-generation services. A fully zero-service-charge workflow also needs a local agent model; its editing quality and speed remain unmeasured. Using an existing Claude/Cursor-style subscription may avoid an additional media bill, but that subscription is still paid. Local computation, downloads, storage, engineering work, and electricity are not literally free.

## What the comparison means

- **Higgsfield-style direction:** coherent subjects, intentional camera language, scene continuity, and a consistent look. Apply these principles to real footage and stock selection. Arbitrary photorealistic scene generation is a separate compute-intensive capability; this audit does not establish an equally capable free local substitute.
- **Claude Code/Cursor-style autonomy:** understand the goal, inspect available material, execute domain operations, observe results, repair defects, and finish without repeated “continue” prompts. The application must own deterministic media work and job lifecycle; the model should own creative choices.
- **Professional editing:** a clear story, relevant shots, motivated cuts, intelligible dialogue, deliberate sound, readable typography, consistent color, and correct delivery. Transition count is not a quality metric.

No head-to-head comparison with those products or any particular model version was performed.

## Current baseline

### Present and worth reusing

- Edit plans and `apply_plan(commit=true)` already assemble clips. Approved-plan assembly and undo have focused coverage.
- Local visual retrieval uses SigLIP2; transcript search and stock metadata complement it. `find_shot_candidates` already distinguishes visual, spoken, and catalog evidence.
- Existing tools cover captions, text styles, layouts, keyframes, transitions, speech-driven ducking, local speech synthesis, and structural timeline QC.
- `inspect_timeline` renders composited stills. `TimelineRenderer` already renders a timeline range to MP4.
- Export jobs already have stable IDs, status, progress, cancellation, errors, and warnings through `manage_exports`.
- Custom OpenAI-compatible endpoints already support local agent integration; loopback endpoints do not require an API key. Tool-result images are preserved by the custom Chat Completions transport.
- `get_capabilities` already reports prerequisites and unavailable operations. This is the correct planning input rather than assuming every advertised tool can run.

### Observed in the running standard build

Read-only MCP discovery returned **78 tools**, with **162,410 bytes** of compact JSON definitions and no next cursor. This is schema size, not a measured token count or per-turn network total.

Capabilities reported visual search, local speech, loudness matching, de-breath, drones, and stock access available. Openverse and Pixabay were configured; Pexels was not. Availability is prerequisite readiness, not proof that every request succeeds.

Hosted video/image/audio generation, cloud transcription, upscaling, bundled denoising, and `enhance_voice` were unavailable. MCP image-input support was `unknown/client_dependent`, not verified vision support.

Apple local transcription is independent of the optional `BundledSpeech` trait. System/Piper TTS is also usable without bundled MLX denoising. Installed Piper language coverage reported `en-GB`, `en-US`, and `ml-IN`; voice quality was not benchmarked.

## Priority 0 — Make the promised edit match the output

### 1. Positive audio gain is lost in composition

**Evidence:** [CompositionBuilder.swift:652–656](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L652), [1021–1030](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L1021), and [1069–1078](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L1069) clamp gain/envelopes to `[0,1]`.

**Impact:** a quiet clip at unity volume can receive a positive loudness correction in model state while the rendered signal receives no requested boost. This undermines automatic dialogue finishing. Existing ramp tests correctly protect AVFoundation's legal volume range; they do not prove achieved output loudness.

**Change:** implement positive gain in a shared off-main audio-processing/preparation stage that supports amplification and peak control. Keep AVFoundation mix parameters in their legal range. Reuse the existing enhancement infrastructure and define which gain is baked versus applied by the envelope so it cannot be applied twice. Removing the clamp alone is not a valid fix.

**Acceptance:** render a known quiet signal with positive gain, decode the output independently, and verify the expected level change before limiting. Verify attenuation, fades, linked/nested clips, and preview/export parity. Test actual samples, not only settings or planned ramps.

### 2. Breath and sibilance regions use the wrong time domain

**Evidence:** [BreathDetector.Region](../Sources/CompositorPro/Audio/Analysis/BreathDetector.swift#L10) stores seconds. [CompositionBuilder.gainDips](../Sources/CompositorPro/Preview/CompositionBuilder.swift#L958) compares those values with source-frame trims and passes them into frame-domain mapping. Export passes cached regions without converting them.

**Impact:** dips may be displaced or disappear, especially after trimming and speed changes. An “enabled” effect is insufficient evidence that the intended sound was treated.

**Change:** establish one source-seconds → exact source-time/frame → timeline mapping at the shared audio boundary. Reuse the clip time map, with explicit rounding and clipping to the audible interval. Apply the same contract to de-ess regions.

**Acceptance:** use a detected region well after time zero; test untrimmed and trimmed clips, fractional speed, project frame rates, regions crossing a trim boundary, and empty regions. Check the dip's position in rendered audio.

### 3. Audio analysis and render preparation lack one completion contract

**Evidence:** [EditorViewModel+AudioEnhance.swift](../Sources/CompositorPro/Editor/ViewModel/EditorViewModel+AudioEnhance.swift) launches unstored detached work in enhancement/loudness operations, skips some failures through `try?`, and commits without revalidating the original timeline/source/trim/settings. [ExportService.swift:565–593](../Sources/CompositorPro/Export/ExportService.swift#L565) explicitly awaits standalone denoise only, can log a denoise failure and export original audio, and reads cached breath/de-ess regions. [TimelineRenderer.swift:32–38](../Sources/CompositorPro/Preview/TimelineRenderer.swift#L32) omits those region resolvers.

**Impact:** immediate export or review may use incomplete processing. Late analysis can affect changed state. A review render can disagree with the final export.

**Change:** introduce one shared prepared-render input for preview/review/export. It resolves enabled audio stages over an immutable timeline/media snapshot, waits for required analysis, and returns prepared assets plus explicit outcomes. Jobs have stored cancellation ownership; results are committed only after identity/revision/configuration checks. Keys must include relevant source identity/version, span, speed, and processing settings. Bound and deduplicate expensive work. Stage files outside the live package and install through `ProjectPackageCoordinator` when persistence is needed.

For user-requested processing, failure must become an observable failed/blocked outcome or an explicitly accepted degraded result. It must not look like fully processed success.

**Acceptance:** cold-cache immediate export matches warm-cache export; review and final export use the same treatment. Cancellation, trim/source changes, timeline switching, Save As, and close cannot commit stale results. Corrupt/offline media produces actionable terminal status.

### 4. Plan readiness and commit validation can disagree

**Evidence:** [ToolExecutor+Plan.swift:401–483](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift#L401) only checks source length in readiness when an explicit source span exists. [resolvePlacement](../Sources/CompositorPro/Agent/Tools/ToolExecutor+Clips.swift#L229) also rejects a timeline duration longer than the source. `applyPlan` can change approved status to ready before `addClips` fails. [EditorUndo.perform](../Sources/CompositorPro/Editor/EditorUndo.swift#L14) groups changes but does not roll back thrown work.

**Impact:** an invalid assembly may be reported ready and still change plan state on failure. This scenario is source-traced; it was not separately reproduced through a live assembly request.

**Change:** prepare an immutable placement batch through the same domain validation used by commit. Readiness consumes that result. Commit plan status and placements only after the complete batch is valid, with one coherent undo action and no throwing partial mutation path.

**Acceptance:** duration-only shot longer than source fails without changing timeline, plan status, selection, or undo history. Dry-run and commit agree. Repeating an applied plan reports a no-op without duplicating clips.

## Priority 1 — Complete one brief autonomously

### 5. Add an application-owned production run

**Evidence:** [AgentService.swift:538 onward](../Sources/CompositorPro/Agent/Chat/AgentService.swift#L538) owns a conversational tool loop. [AgentInstructions.swift:239–243](../Sources/CompositorPro/Agent/Tools/AgentInstructions.swift#L239) explicitly says the agent cannot retrigger itself after long jobs and asks the user to continue. Existing export jobs solve export lifecycle, not whole-production continuation.

**Smallest coherent architecture:**

1. Persist a production record beside the existing edit plan: run ID, project/timeline IDs, source revision, brief, phase, owned job IDs, decisions, warnings, terminal result, and output identity.
2. Keep one coordinator as the mutable state owner. Main-actor code publishes lightweight UI state; media work executes through bounded background services.
3. Drive phases from job completion: assess material → select/script → prepare assets → assemble → finish audio/style → review render → repair → export → verify output.
4. Reuse existing plan, mutation, package, and export operations. Do not introduce a second editor or generic workflow framework.
5. Snapshot inputs before awaits and revalidate before every mutation. Completion events resume only their matching run and revision. Duplicated callbacks/retries must be idempotent.
6. Resume persisted runs only after resolving current project/assets and lifecycle state. Unsupported or missing material is an explicit block with the smallest actionable question.
7. Keep mutations short and undoable. Never hold an AppKit undo group across background waits or absorb unrelated user edits. For the first workflow, prepare an edit before one assembly commit; subsequent revision requests remain separately undoable.

In-app continuation can invoke the selected agent through its owned run. External MCP clients should receive stable job receipts and inspectable terminal state; the app cannot assume arbitrary external clients will restart their own conversations after an event.

**User experience:** infer sensible defaults from the brief, source material, and intended platform. Ask only when a consequential creative requirement cannot be inferred or required material is missing. Show phase/progress and a playable result. The default goal is completion, not a plan left for the user to execute.

**Acceptance:** one request finishes a 30–60-second edit without “continue” messages. Slow indexing/import/analysis do not strand the run. Cancel, close/reopen, repeated callbacks, changed media, user edits, and failed export all reach correct observable states. Read back project state and inspect the output independently of tool receipts.

### 6. Choose shots from evidence, then build sequence continuity

**Evidence:** [ShotCandidates.swift:258–280](../Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift#L258) marks remote results as catalog evidence. Candidate receipts omit thumbnail/dimension fields available in stock hits. Local visual and spoken retrieval already exist; search does not need to be rebuilt.

**Change:** carry thumbnail, dimensions, source span, and evidence provenance through candidate receipts. Inspect a bounded shortlist before committing footage; for video, sample across the proposed span rather than trusting one thumbnail. Validate downloaded media and update evidence. Preserve asset license/attribution metadata.

Add a compact shot brief: narrative purpose, required subject/action, setting, scale, screen direction, usable duration/handles, crop needs, and continuity constraints. Rank relevant shots first, then choose an ordered sequence with complementary wide/medium/detail coverage and stable subject identity. Raw embedding similarity is not a calibrated editorial-quality score.

Use local measurements for technical rejection: blur, extreme exposure, duplicate frames, insufficient resolution, unavailable crop, and unusable source range. Add more expensive semantic judging only where it changes a decision. Cache on demand with explicit source/model/sampler invalidation.

**Acceptance:** hand-labelled test material exposes misleading titles/thumbnails, repeated shots, wrong subjects, poor vertical crops, and unusable trim ranges. Chosen footage must satisfy the brief and sequence continuity; record why rejected candidates were rejected. Claims such as a specific product/location/person must be supported by actual material.

### 7. Review the rendered result, not just timeline metadata

**Evidence:** [inspect_timeline](../Sources/CompositorPro/Agent/Tools/ToolExecutor+InspectTimeline.swift#L8) returns at most 12 stills at a maximum dimension of 512 and skips individual frame failures. [TimelineQCAudit](../Sources/CompositorPro/Agent/Tools/TimelineQCAudit.swift) checks structure rather than motion, aesthetics, or audible output. Per-track gaps may be intentional overlays.

**Change:** reuse the existing range renderer with shared final-export preparation. Review cut boundaries, titles, reframes, and audio transitions in short rendered ranges, then scan the final output. Return a coverage manifest: requested intervals, successfully inspected intervals, failures, and unresolved issues. Never equate partial inspection with a full pass.

Measure rendered silence, loudness, true peak where implemented, decode failures, unintended black/frozen intervals, caption/text clipping, and missing media. Assess pace, continuity, and narrative relevance using supported visual/audio evidence. Image-only clients must not claim to have listened or observed full motion. Local analyzers and human playback remain useful when model modalities are unavailable.

Bound creative repair to two passes initially; return remaining issues honestly. Repair only evidenced problems. Do not fill every per-track gap or add arbitrary transitions to satisfy a structural warning.

**Acceptance:** deliberately broken audio, missing processing, clipped text, poor reframing, and a failed sample are detected or marked unverified. Fixes improve the measured defect without changing unrelated timing. Final-output decoding and full human playback verify delivery.

## Priority 2 — Make local reasoning practical

### 8. Reduce repeated context and unnecessary model decisions

**Evidence:** [AgentService.swift](../Sources/CompositorPro/Agent/Chat/AgentService.swift#L538) builds the full in-app tool list and replays conversation into subsequent requests. Tool execution is serial. The measured MCP schema set is substantial, although it is not identical to the in-app request payload.

**Change:** expose task-relevant in-app tool groups with an explicit discovery path for additional tools. Retain exact current state, stable IDs, unresolved jobs, user constraints, and necessary tool-call/result pairs; summarize superseded conversation and avoid replaying obsolete image evidence. Keep canonical transcripts in project storage and return relevant spans. Compute timing, layout, fades, and mixing through deterministic domain operations.

Parallelize only independent read/analysis work with bounded resource use. Keep conflicting mutations serialized. External MCP clients control their own context strategy; do not assume they support dynamic discovery or compaction identically.

The measured machine has an M4 Pro and 24 GiB unified memory. A quantized small/mid-sized local model is a reasonable benchmark starting point, not a proven quality or performance recommendation. Test tools and image support for the exact model/backend. Leave memory for rendering and decoding; avoid concurrent heavy inference and export without measurement.

The custom endpoint already supports a local OpenAI-compatible base URL. Ollama documents tools and vision support, but model capability is still required, and context length must be configured separately from ordinary OpenAI-compatible requests. A text-only coding model is not automatically a visual editor.

**Acceptance:** compare identical briefs before/after using measured request tokens, peak memory, latency, tool errors, completion rate, and human edit quality. Context reduction must preserve constraints and improve cost/latency without losing correctness. No local-model trial was run in this audit.

## Editorial recipes: concrete defaults for professional results

Encode a small number of recipes in existing skills and shared style/domain operations. Each recipe defines narrative structure, shot roles, rhythm, typography, sound hierarchy, grade intent, and delivery. These are editable creative defaults, not inflexible duration rules.

### A. Interview or talking-head short — strongest first release

- Start on a complete, compelling thought. Preserve meaning, qualifiers, and speaker intent when removing pauses or repetition.
- Build one idea with a clear payoff. Read the edited transcript for continuity before rendering.
- Use relevant B-roll to clarify a claim or cover a justified cut; retain the speaker when presence matters.
- Use phrase-level captions with one consistent style, sensible line breaks, platform-safe placement, and stable hierarchy.
- Prioritize original dialogue; duck a suitable music bed, preserve useful room tone, and smooth audible edit boundaries.
- End deliberately with the payoff or requested action, not an arbitrary truncation.

### B. Product or service film

- Establish the product and viewer problem early; show evidence of use, a detail, and a result.
- Maintain the exact supplied product's appearance. Stock can establish context, but cannot stand in as proof of a specific product feature.
- Prefer motivated cuts and restrained movement. Use consistent type, a small color system, and one grade direction while protecting skin/product colors.
- Place sound effects at motivated actions; leave space around speech. Finish music intentionally rather than abruptly cutting it.

### C. Travel, event, or real-estate montage

- Establish place, people/action, details, and a closing moment. Sequence spatially and temporally coherent material.
- Vary shot scale and duration according to action and emotional pace. Avoid near-duplicates and unmotivated direction reversals.
- Use natural ambience to connect shots. Music accents can support the edit; not every cut needs to land on a beat.
- Validate vertical reframing over motion, not just one frame. Use supplied footage for identity-critical locations.

For all three, recommend a configurable house audio target and platform preset. An initial web-video benchmark could use approximately −16 LUFS integrated and ≤ −1 dBTP, but these are proposed house targets, not universal platform requirements or measurements of the current renderer. Silence/insufficient speech must be explicit, not amplified blindly.

## Practical zero-service-charge stack

- **Media:** user footage first; existing configured Pixabay for supported stock, and Openverse for images/audio. Search access can be free while individual assets still have attribution/use requirements. Carry that metadata into delivery.
- **Transcription:** Apple's local speech pipeline for supported installed languages.
- **Narration:** original recorded voice when available; installed system/Piper voices when requested and suitable. Do not promise premium voice performance without listening tests.
- **Visual retrieval:** the existing local SigLIP2 index, with selective inspection of retrieved candidates.
- **Sound:** original production sound, licensed free recordings/music, local DSP, and existing drone synthesis where aesthetically appropriate. Drones are not a substitute for every musical brief.
- **Rendering:** existing native composition/export pipeline, after correctness and shared-preparation fixes.
- **Agent:** a tested local tool-capable model for zero inference-service charges, or an already-paid agent for a separate “no additional media-service spend” mode.

Pexels is not a dependable new-user prerequisite today: its official API page says new API key issuance is paused. Existing keys have documented default quotas. The adapter still uses `/videos/search` while current documentation recommends `/v1/videos/`; verify compatibility before changing it. This audit does not establish that the old route fails.

Offer zero-spend as an explicit execution constraint enforced at tool dispatch, not merely a prompt preference. When a brief requires unavailable original footage or generation, report that constraint and ask for the specific missing material; do not silently spend or misrepresent stock as bespoke footage.

## Delivery order and dependencies

1. **Correctness foundation:** audio gain/time mapping, lifecycle ownership, shared prepared-render inputs, and consistent plan validation. Prove with rendered fixtures and failure/undo tests.
2. **One end-to-end recipe:** talking-head/source-footage brief through automatic completion. Build on the existing plan and export job infrastructure.
3. **Evidence and review:** verified shot shortlists, coverage-aware rendered inspection, and bounded repairs. Use the same final-export preparation.
4. **Local efficiency and broader recipes:** context reduction, local-model benchmarking, then product/montage variants and reference-look matching.

Do not make bundled MLX denoising a prerequisite for the first release. Repair its packaging separately. Avoid expanding into arbitrary local video generation before the footage-to-finished-edit workflow meets its acceptance criteria.

## Proposed release benchmark

These are targets, not achieved results.

- Use 10 fixed briefs across the three recipes, with adequate source material, varied orientations, quiet dialogue, imperfect lighting, and some intentionally irrelevant clips.
- Capture the current baseline and the improved build using identical material and model configuration; repeat stochastic runs enough to report variability.
- Target at least 9/10 complete exports without manual timeline repair, median zero additional user messages, and zero paid-service calls in zero-spend mode.
- Require exact delivery dimensions/rate/duration constraints, no unintended black gaps or decode failures, readable platform-safe text, and independently measured rendered audio.
- Have three reviewers score story, shot relevance/continuity, pacing, sound, typography, and color on a 1–5 rubric. Proposed gate: median at least 4 in each category, with no critical factual or delivery defect. Keep technical pass/fail separate from taste.
- Record time to first playable cut, total time, manual interventions, tool calls/tokens, peak memory, repair count, and unresolved warnings. Do not claim a speed gain without a comparable baseline.
- Add deterministic engineering cases for cancellation in every phase, stale completion after edits, reopen, offline/corrupt assets, failed export, duplicate callbacks, repeated requests, no-op, exact undo, and concurrent project-package operations.
- Exercise orchestration through MCP as well as the UI, inspect project/output state independently, and test a representative local agent rather than only direct internal tool calls.

### Manual acceptance scenario

Setup: isolated project with interview footage, several relevant B-roll clips, one music bed, and quiet dialogue; use an available local agent or record the paid model used.

Request: “Make a 45-second vertical film about this product for Instagram. Use my footage, keep the speaker's meaning, add readable captions and restrained music, and export it. No paid services.”

Expected: one coherent finished edit, no continuation prompt, correct product identity, relevant coverage, clean audio, safe captions, explicit terminal export status, and a playable file. Review the entire output with sound. Repeat with cancel, an offline source, a timeline change during analysis, and close/reopen. Verify undo preserves unrelated user edits. UI behavior remains unverified until a person confirms these scenarios.

## Verification performed and limits

- Standard local app built/opened using `scripts/dev.sh --no-stream`; process and signature were verified.
- Missing Metal compiler installed with `xcodebuild -downloadComponent MetalToolchain`.
- Speech-enabled Swift compilation passed, but optional packaging failed in MLX `fp_quantized.metal` with `BlockMMA` default-constructor and Metal address-space/template errors. A complete speech-enabled package was not verified.
- Ran `swift test --filter 'PlanEditToolTests|AudioMixRampTests|LoudnessAnalyzerTests|AgentProviderTests|ShotCandidateBundleTests|QCTimelineToolTests'`: **51 tests across 7 suites passed**. Linker emitted existing macOS 26.2-versus-26.0 dependency warnings.
- Focused coverage includes plan discovery and QC through MCP. It does not establish rendered video quality, all assembly failure paths, or a complete agent-driven production workflow.
- Queried the running app through MCP initialization, `tools/list`, and `get_capabilities` only. No user project mutations or credit-spending provider calls were made.
- No complete prompt-to-export benchmark, rendered reproduction of the identified audio defects, full test suite, local-model evaluation, creative-quality review, or external-agent comparison was performed.
- Existing uncommitted application/test work was preserved. Audit output consists of this report and its companion canvas; no source fixes, commit, or push were made.

Older documents contain useful design goals but are not current implementation evidence. In particular, plan assembly, capability reporting, custom-provider image replay, and energy-domain loudness analysis already exist or have focused passing coverage. Reconcile future tickets against source rather than repeating those as missing features.

## External references

Official references checked during the audit; provider availability can change.

- [Higgsfield cinematic direction](https://higgsfield.ai/cinematic-video-generator) and [pricing](https://higgsfield.ai/pricing): relevant creative workflow comparison; credit-priced generation. Marketing pages differ on exact free access/limits, so no free-generation guarantee is assumed.
- [Pexels API availability](https://www.pexels.com/api/) and [documentation](https://www.pexels.com/api/documentation/): paused new-key issuance, documented API usage and default quotas.
- [Openverse API](https://api.openverse.org/) and [authentication/throttling](https://docs.openverse.org/api/reference/authentication_and_throttling.html): free image/audio search with rate limits; not a video catalog.
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility) and [context length](https://docs.ollama.com/context-length): local integration path; tool/vision capability depends on the selected model and context configuration.
