# Agent-driven professional video production: technical design

**Status:** analysis and implementation note  
**Scope:** raise the in-app agent from a tool-calling editor to a reliable editorial system that can produce polished videos from user footage, stock media, stills, music, ambience, and optional generated assets.  
**Repository reviewed:** CompositorPro Swift 6.2 macOS application.  
**Important:** this note describes the architecture and delivery order. It does not claim that the workflow is implemented.

## 1. Executive conclusion

The repository is not a basic video editor. It already contains a substantial editing substrate:

- shared in-app/MCP tools through `Agent/Tools/ToolExecutor.swift`;
- persistent edit plans in `Agent/Plans/EditPlan.swift`;
- local visual/spoken search and stock candidate retrieval;
- timeline mutation, linked clips, nesting, layouts, keyframes, transitions, captions, color, effects, speed ramps, beat sync, audio ducking, and exports;
- Core Image/Metal compositing in `Compositing/`;
- optional image/video/audio generation through `Generation/`;
- project-package persistence and undo.

The main limitation is not the absence of individual features. It is the absence of a **verified production workflow** that connects them:

```text
brief -> editorial plan -> retrieval -> visual/audio verification -> assembly
      -> mix/graphics/effects -> render review -> bounded repair -> export/credits
```

Today, retrieval can return a usable-looking candidate, but candidate metadata is not proof that the shot depicts the requested subject or action. The plan can describe shots, but `apply_plan` is not yet a complete atomic assembly operation. Chat can finish before asynchronous generation or enhancement finishes. A strong model cannot compensate for missing visual evidence, stale asynchronous commits, incomplete audio verification, or a missing review gate.

The recommended strategy is therefore:

1. make capabilities and evidence truthful;
2. build one complete stock/B-roll production path;
3. add professional editorial primitives and restrained motion design;
4. add durable production-run orchestration and rendered review;
5. only then expand synthetic generation and style playbooks.

## 2. Current architecture and extension points

### Agent and tool layer

`AgentService` runs the model/tool loop. `ToolExecutor` is the shared mutation boundary for in-app chat and MCP. `ToolDefinitions.swift` exposes a large existing vocabulary, including:

- `get_capabilities`, `get_timeline`, `inspect_timeline`, `inspect_media`;
- `search_media`, `find_stock_media`, `find_shot_candidates`, `import_media`;
- `plan_edit`, `apply_plan`, timeline and clip mutations;
- `apply_layout`, `set_keyframes`, `apply_transition`, `apply_effect`;
- captions, speech, ducking, beat sync, style presets, QC, and export management.

This is the correct foundation. Do not create a second editor API for the agent. Any new high-level operation should resolve into the same editor-owned mutations used by the UI and should produce one coherent undoable result.

### Timeline and compositing

`Models/Timeline.swift` owns timelines, tracks, clips, markers, and transitions. Clips already support static settings, effect stacks, keyframe tracks, text animation, nested timelines, linked audio, and source timing. `Compositing/FrameRenderer.swift`, `EffectRegistry.swift`, `TextAnimator.swift`, Core Image kernels, and Metal shaders provide a useful render path.

The current effect architecture is descriptor-driven: an effect has a stable type, validated parameter specifications, optional keyframed parameters, and a render closure. This can grow safely, but new effects must be implemented in the shared renderer rather than as agent-specific recipes.

### Retrieval and stock

`Search/` provides local visual and spoken search. `MediaSources/` provides stock-provider adapters. `Agent/Retrieval/ShotCandidates.swift` combines library and stock rows and preserves some evidence, licensing, readiness, and source-span data.

The missing layer is **shot verification**:

- candidate retrieval is not shot acceptance;
- titles, filenames, embeddings, and provider scores are not proof of visible content;
- coarse frame sampling is not a precise edit boundary;
- attribution in chat or a plan is not durable asset provenance.

### Generation and asynchronous work

`GenerationService` already has placeholders, backend job monitoring, and recovery for pending jobs. This should be reused. Generation is not a substitute for editing: generated shots need the same inspection, selection, timing, continuity, provenance, and review as stock or user footage.

The same principle applies to audio enhancement and exports: an immediate tool response must not claim a completed result when work is still running.

## 3. Target product behavior

A representative request should be handled as a production run, not a sequence of disconnected tool calls:

> “Make a polished 30-second vertical product film from my interview and product footage. Find missing lifestyle B-roll, keep the tone premium and modern, use restrained motion graphics, add captions, music, ambience, and export a social-ready version.”

The agent should:

1. clarify only decisions that materially change the result: audience, destination, duration, source constraints, tone, narration, and whether stock/generated media is allowed;
2. inspect runtime capabilities and identify blocked requirements before making paid or irreversible requests;
3. create or update a persistent brief and shot/sound plan;
4. search local media and stock in bounded, diverse batches;
5. inspect representative frames/contact sheets and reject unsuitable candidates;
6. import accepted sources with permanent provenance;
7. prepare the entire cut before mutating the timeline;
8. apply the cut through one validated assembly operation and one undo group;
9. add sound roles, ducking, captions, graphics, transitions, and a restrained style;
10. render a draft through the actual composition path;
11. run deterministic QC and editorial review against the brief;
12. repair only identified failures, within a bounded iteration budget;
13. export and return a receipt containing the verified revision, output path, credits, warnings, and unresolved items.

The agent must report `blocked`, `waiting`, `running`, `completed`, `failed`, `cancelled`, and `no-op` distinctly. A successful API call is not proof that a video was produced.

## 4. Core domain model to add

### 4.1 Editorial brief and plan

Extend `EditPlan` rather than storing creative intent only in chat. The plan should persist:

- audience, goal, duration, aspect ratio, delivery destination, language, tone, and realism/source policy;
- narrative sections such as hook, development, proof, payoff, and CTA;
- stable shot IDs with purpose, required subject/action/location, shot size, motion, exclusions, source type, duration, handles, and continuity notes;
- timed script segments and caption policy;
- sound cues with roles: dialogue, narration, music, ambience, spot SFX, and transition accents;
- chosen candidate, inspected evidence, source span, rejection reasons, unresolved requirements, and provenance;
- plan revision and dependency invalidation rules.

The plan is the authoritative creative state. Timelines remain the authoritative edit state. A plan revision must invalidate dependent candidates and review results instead of silently reusing stale work.

### 4.2 Prepared assembly

Introduce an immutable, validated preparation value before timeline mutation. It should contain:

- project/timeline/plan revisions;
- resolved source media IDs and source spans;
- destination track IDs and placement frames;
- linked audio policy;
- transitions, layouts, text, captions, effects, and sound cues;
- expected duration and warnings;
- stable idempotency key.

Preparation performs all validation and media readiness checks. Commit performs no asynchronous work and opens one undo group only after preparation succeeds. Commit rejects stale timeline or plan revisions and leaves the timeline untouched on failure.

### 4.3 Production run

Add one project-owned production-run coordinator. It should persist:

- run ID, plan ID/revision, project/timeline revision;
- current stage and completed operation IDs;
- dependency/job IDs for import, generation, analysis, render, and export;
- cancellation/supersession state;
- review findings and repair attempts;
- terminal outcome.

The coordinator references existing generation, import, analysis, and export services. It must not duplicate them or busy-poll the model. Completion events advance the next eligible step. Idempotency keys prevent duplicate paid submissions, imports, placements, or repairs after restart.

### 4.4 Evidence and review records

Every automatic selection and completion claim should carry evidence:

- source asset and content fingerprint;
- inspected frame times or audio analysis range;
- visual/spoken/catalog evidence separately;
- acceptance score and rejection reasons;
- source/timeline/processing revision;
- reviewer type: deterministic, model-assisted, or human-required.

Review findings should point to stable shot/clip IDs and be invalidated by the revisions that affect them.

## 5. Retrieval-augmented editorial pipeline

### Stage A: understand the brief

Convert the request into structured intent. Keep inferred decisions visible and editable. Ask a question only when the missing choice changes sourcing, duration, destination, or cost.

### Stage B: retrieve locally first

Use `search_media` for existing footage, with visual and spoken scopes selected intentionally. Search by shot requirement rather than one broad prompt. Use transcript hits directly as source spans; the model must not reconstruct seconds-to-frames arithmetic.

### Stage C: retrieve stock with diversity

Use `find_shot_candidates` for missing coverage. Retrieve a bounded shortlist across configured providers before applying the final limit. Preserve provider rank and catalog evidence. Request video explicitly for motion-led shots and do not silently replace it with a still.

### Stage D: inspect and reject

For local media, use overview/storyboard inspection followed by focused frame ranges. For remote media, download only a bounded candidate set, create thumbnails/contact sheets, and inspect representative frames before acceptance. Verify:

- visible subject, action, location, and realism;
- shot size, camera motion, direction, and continuity;
- usable source duration and handles;
- crop/resolution/orientation;
- duplicates and near-duplicates;
- named-location/entity provenance where appearance alone is insufficient.

Allow “no suitable candidate”. A professional system must prefer an explicit gap over confidently choosing the wrong shot.

### Stage E: import and preserve provenance

Import accepted media through `ProjectPackageCoordinator`. Persist provider, asset ID, creator, source URL, license, attribution, retrieval date, and content fingerprint in the media manifest. Credits must survive plan deletion, reuse, save/reopen, Save As, and export.

### Stage F: assemble through a shared operation

Resolve all shots and dependencies first, then commit through shared editor mutations. One request should produce one understandable undo action. Reapplying the same prepared operation should be a no-op.

## 6. Professional editing feature roadmap

The goal is not to apply every effect to every clip. The agent needs motivated, style-consistent choices.

### Already available and should be orchestrated

- keyframed position, scale, rotation, opacity, crop, blur, and volume;
- split screen, picture-in-picture, grid, and nested timelines through `apply_layout`;
- dissolve, slide, push, and dip-to-black transitions;
- speed ramps, freeze frames, beat sync, J/L audio offsets, fades, and crossfades;
- captions with animated text presets and style controls;
- color presets, color wheels/curves/LUTs, grain, glow, vignette, chroma key, clarity, sharpening, and noise reduction;
- audio ducking, voice cleanup, speech synthesis, drones, loudness tools, and export QC.

These should be exposed as high-level recipes, not a long list of low-level calls. For example: “make this a premium product montage” should resolve to a brief-aware style, selected shot cadence, restrained transitions, title hierarchy, music ducking, and color consistency—not blindly add ten effects.

### P0/P1 additions for professional output

1. **Verified shot assembly:** source handles, continuity-aware ordering, linked audio policy, stable track roles, and atomic commit.
2. **Dialogue-first mix:** explicit audio roles, speech-driven ducking with attack/hold/release, measured integrated loudness, true-peak/headroom checks, and preview/export parity.
3. **Motion-graphics primitives:** reusable title lower-thirds, callouts, logo bugs, progress bars, chapter cards, CTA cards, and end cards. Build these from editor-native text/shape layers and keyframes, not generated video frames.
4. **Animation presets:** fade, slide, pop, scale overshoot, type-on/word reveal, highlight sweep, parallax push, gentle handheld drift, and controlled punch-in. Presets need named intent, parameter bounds, reduced-motion option, and deterministic rendering.
5. **Continuity helpers:** match grade across shots, preserve screen direction, alternate shot sizes, detect repeated/near-duplicate coverage, and maintain title-safe/action-safe regions.
6. **Render review:** inspect selected frames and motion boundaries, measure audio, verify captions, and report unresolved issues before completion.

### P2 additions after the first production path works

- mask/roto and motion tracking only if a dependable tracking data model and renderer are available;
- object-aware reframing and subject isolation with explicit quality/failure reporting;
- richer particle, light-leak, film-burn, halation, displacement, and camera effects as bounded reusable effect descriptors;
- user style references and versioned filmmaking playbooks;
- reference-guided generated scenes, music, SFX, and higher-quality narration.

Do not promise motion tracking, mask transitions, or a built-in SFX library until their underlying media/render/tool contracts exist. Do not use generated video to render readable titles; authored text belongs in the editor.

## 7. Effect and animation architecture

### Effect registry

Continue extending `EffectRegistry` with:

- stable effect IDs and versioned parameter schemas;
- explicit category, defaults, ranges, units, and resource dependencies;
- deterministic frame evaluation;
- render-safe bounds and cancellation-aware preparation for expensive resources;
- preview/export parity;
- optional parameter keyframes using the existing `EffectParam.track` model.

Separate **clip effects** from **timeline transitions** and **motion-graphics templates**. A transition owns overlap, handles, audio behavior, and removal. A template owns multiple layers, text placeholders, timing, and safe-area rules. A clip effect should not silently create unrelated clips or tracks.

### Preset contract

Each agent-facing preset should declare:

```text
id, intent, supportedMedia, parameters, defaults, duration policy,
required handles, safe-area policy, reduced-motion behavior,
preview cost, export behavior, and failure conditions
```

The agent chooses a preset by editorial intent. It does not synthesize arbitrary effect parameter JSON without validation. Presets should be composable but have an explicit conflict policy: for example, one owner for title entrance, one owner for opacity, and no stacked duplicate blur unless requested.

### Quality rules

- use transitions for relationships between adjacent shots, not overlapping keyframes as an imitation;
- use `apply_layout` for composition and `set_keyframes` for intentional animation;
- keep transitions and motion subordinate to story, dialogue, and readability;
- cap effect density and transition frequency per style/brief;
- test at final delivery dimensions, not only a large preview;
- include reduced-motion and caption readability checks.

## 8. Audio architecture and correctness gates

The current audio surface is valuable but needs a single processing contract shared by preview, export, analysis, and agent receipts.

Required repairs before claiming professional output:

1. calculate integrated loudness in the energy domain with channel-aware weighting and explicit silence/short-input behavior;
2. map analysis regions from source seconds to timeline frames through one shared conversion handling trim, speed, placement, nesting, and half-open boundaries;
3. support positive gain in the actual rendered processing path; AVFoundation envelope values must not be confused with amplitude gain capability;
4. scope loudness, breath, and sibilance caches by analysis type, source identity/version, algorithm version, and parameters;
5. make enhancement jobs owned, cancellable, stale-result-safe, and inspectable;
6. make export await the processing snapshot required by the requested output;
7. add non-speech audio inspection for ambience, music, SFX, clipping, loudness, silence, channels, and mix balance.

A mix operation should accept stable clip/track IDs and explicit roles, then return measured before/after values, generated automation, warnings, and changed IDs. Human audition remains necessary for aesthetic sound-design judgments.

## 9. Capability truth and provider boundaries

`get_capabilities` must be the source used by planning, UI, tool descriptions, and execution. It should distinguish:

- build feature excluded;
- model/resource not installed or not prepared;
- credential absent;
- provider unavailable or rate limited;
- modality unsupported by the selected endpoint;
- operation currently running;
- operation ready.

A chat API key does not imply hosted image/video/audio generation. Local speech, drones, denoise, stock providers, and generation backends have separate prerequisites. When a requested requirement is unavailable, the agent must either ask permission for a material substitution or report a blocker.

## 10. Delivery phases and gates

### Phase 0 — evidence and trust

- establish fixed fixtures and outcome metrics;
- preserve inspection images on every supported endpoint;
- unify capability reporting;
- repair audio timing, loudness, gain, caches, cancellation, and export barriers.

**Gate:** the agent receives the actual visual evidence, audio changes are audible and measurable, and stale/cancelled work cannot mutate the project.

### Phase 1 — first complete stock/B-roll film

- extend `EditPlan` into a brief/shot/sound plan;
- implement inspected shot candidates and permanent provenance;
- implement atomic `apply_plan` assembly;
- add project-owned production runs and resumable dependencies;
- implement dialogue-first mixing and rendered review.

**Gate:** one request can create a verified 30-second film from supplied footage plus stock, with captions, music/ambience, credits, cancellation, undo, and export.

### Phase 2 — motion design and style system

- add reusable title/lower-third/CTA templates;
- add bounded animation and transition presets;
- add continuity/style checks and delivery-specific safe areas;
- version playbooks and user style preferences.

**Gate:** human reviewers prefer the result over a basic cut, while effects remain motivated and readable.

### Phase 3 — generated media and advanced intelligence

- integrate one video/image/audio provider through the existing job lifecycle;
- support reference continuity and cost authorization;
- inspect generated media before placement;
- add advanced tracking/masking only with reliable contracts.

**Gate:** generated assets are handled as production dependencies with observable cost, recovery, provenance, and quality review.

## 11. Evaluation and acceptance metrics

Do not use tool-call count or model confidence as quality metrics. Maintain an isolated fixture suite covering:

- narrated stock B-roll;
- product footage with distractor stock;
- interview cleanup and captions;
- ambience/SFX placement;
- vertical/social delivery;
- missing keys/models, cancellation, stale edits, failed downloads, and no suitable candidate.

Measure:

- shot subject/action relevance and coverage completeness;
- inspected-evidence rate for accepted shots;
- source-span and continuity correctness;
- caption bounds/readability;
- dialogue intelligibility, integrated loudness, true peak, and ducking behavior;
- unintended gaps, black frames, missing media, and pending processing;
- export completion and provenance completeness;
- human ratings for pacing, restraint, coherence, and professional finish;
- latency, cost, context size, repair count, and corrective user edits.

Test agent tools through MCP discovery, schema, invocation, terminal status, state readback, undo, save/reopen, and independent output inspection. A success receipt alone is insufficient.

## 12. Recommended first implementation slice

Build the smallest complete vertical slice before adding a large effect catalog:

- a 30-second narrated or interview-led film;
- six to eight planned shots chosen from local media and one configured stock provider;
- inspected candidate frames and explicit rejection reasons;
- one primary video track, one B-roll track, dialogue, music, and ambience roles;
- captions, one restrained title treatment, two motivated transitions, one style preset, and dialogue ducking;
- draft render, deterministic QC, one bounded repair pass, final export, and credits receipt;
- cancellation, restart, no-op reapplication, one-step undo, save/reopen, and stale-revision tests.

Once this path is reliable, additional effects and generation providers become multipliers rather than sources of impressive but fragile demos.

## Repository evidence consulted

- `Sources/CompositorPro/Agent/Tools/ToolExecutor.swift`
- `Sources/CompositorPro/Agent/Tools/ToolDefinitions.swift`
- `Sources/CompositorPro/Agent/Tools/AgentInstructions.swift`
- `Sources/CompositorPro/Agent/Plans/EditPlan.swift`
- `Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift`
- `Sources/CompositorPro/Models/Timeline.swift`
- `Sources/CompositorPro/Models/Effect.swift`
- `Sources/CompositorPro/Compositing/EffectRegistry.swift`
- `Sources/CompositorPro/Compositing/TextAnimator.swift`
- `Sources/CompositorPro/Generation/GenerationService.swift`
- existing `docs/archive/prompt-to-video-technical-todo.md`
- existing `docs/archive/agent-video-quality-engineering-backlog.md`

No source implementation, build, test run, app launch, live provider call, or MCP end-to-end run was performed for this documentation task.
