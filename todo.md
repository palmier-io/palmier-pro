# Explainer production TODO

Goal: produce researched, narration-led explainers from one brief, with mandatory storyboard review before full production and no user “continue” prompts. Every image or video must be used at most once within the finished video. No images or videos may reveal people's faces.

## User requirements — including mid-conversation instructions

- [ ] Complete every unfinished item in this file before declaring the task finished. Continue implementation between coherent commits; a foundation commit is not roadmap completion.
- [ ] Implement remaining work one coherent step at a time, test each step, and commit it. Preserve unrelated working-tree changes through selective staging.
- [ ] Require explicit storyboard approval before full production. Group consequential script, research, rights, voice, and spending decisions; avoid routine shot questions and repeated “continue” prompts (tasks 5, 5a, 8).
- [ ] Never reuse an image/video source within one finished video, including different trims, crops, encodings, nested carriers, or composite wrappers. Enforce this across planning, assembly, revisions, and delivery (task 5b).
- [x] Give every timeline placement its own clip ID; expose stable input identity independently so the Agent can recognize duplicate source use. Identity/move regressions and MCP readback are documented in task 5b; complete output enforcement remains unchecked above.
- [ ] Avoid imagery revealing people's faces; inspect actual selected spans/final framing and block unresolved coverage rather than trusting search tags or sparse thumbnails (tasks 5a, 8, 9, 12).
- [x] Record what/how, acceptance conditions, evidence, and limitations in this file. Maintain these records as implementation continues; do not check off unverified capabilities.
- [ ] Evaluate Pixabay alternatives and repeated-stock selection, including canonical exclusions, pagination, source diversity, rights, and measured retrieval/import quality (task 9a). Public documentation findings alone do not complete this requirement.
- [ ] After implementation, run deep tests, fix failures, rerun affected/full suites, and repeat until acceptance passes. Preserve truthful unresolved UI, temporal, external-provider, and lifecycle checks (verification section and release gates).
- [ ] Only after those gates pass, build/verify a Developer ID-signed app and safely update the existing Compositor Pro installation (signed app update section). Do not substitute ad-hoc signing or mark blocked signing complete.

Based on [Malaysia chip explainer capability audit](docs/malaysia-chip-explainer-capability-audit.md). Reference: [CaspianReport's Malaysia semiconductor explainer](https://www.youtube.com/watch?v=zH5WptvpLCY).

Unchecked items below are planned work, not completed capabilities. Completed items record their verification below. Reference inspection covered captions and storyboard samples; continuous motion and audible mix remain unverified. Provider findings below come from public documentation checked on 2026-11-08, not authenticated search-quality benchmarks.

## Implementation principles

- Reuse existing edit plans, retrieval, speech, assembly, finishing, export, package coordination, and undo. Do not build a parallel editor.
- The model chooses the argument, evidence, and scene purpose. The app owns timing, rendering, dependencies, jobs, and delivery state.
- Authored script, claims, and graphic specifications each have one authoritative owner. Resolved timing and rendered media are derived outputs with explicit revision keys and invalidation.
- UI and Agent callers use the same domain operations. Validate before mutation; commit coherent changes through shared undo.
- Keep filesystem work, media processing, and blocking framework calls off the main actor. Route live package changes through `ProjectPackageCoordinator`.
- Start with supplied research, licensed assets, one narrator, landscape output, and no paid generation. A built-in browser, voice cloning, sponsor recreation, and exact channel-style copying are not initial requirements.
- Fewer user prompts is the objective, not fewer internal tool calls. Measure both separately.
- Storyboard approval is an intentional review checkpoint, not a “continue” prompt. Combine script approval and consequential blockers into that review where possible.

## Golden rule for the Agent — mandatory visual uniqueness

> Never use the same image or video more than once in the same finished video. Check canonical source identity, not only clip IDs, filenames, or download URLs. A crop, different trim, speed change, recolor, resize, re-encode, or duplicate import does not make it a new asset. If unique suitable coverage is unavailable, report a blocker; never silently repeat footage.

This is a hard acceptance condition, not a recommendation or a score penalty. Audio is outside this rule. Different generated scenes may share vector geometry, theme, or geographic data, but must not hide repeated image/video inputs inside separate composites or baked outputs. One continuous visual occurrence can contain successive reveals; replaying it later is reuse. Storyboard thumbnails and review previews do not count as extra uses in the final output. This product rule is stricter than matching the reference's recurring visual environments.

Agent guidance now includes this machine-facing rule and explicitly covers source identity, composites, nested timelines, continuous splits, and preview/audio exclusions. Hard shared enforcement remains task 5b; prompt compliance is not proof of output uniqueness.

## Golden rule for the Agent — no revealed faces

> Do not use images or videos with people's faces revealed. Inspect actual selected source spans and final framing, including motion, crowds, reflections, photographs, and screens. Prefer objects, landscapes, hands, back-facing people, and silhouettes without facial detail. Unknown inspection coverage is unresolved; choose verified faceless coverage or report a blocker. Filenames, search tags, thumbnails, low resolution, fleeting appearances, and unverified crops are not proof.

**What/how:** Agent guidance applies this rule during discovery, storyboard selection, replacement, and final review. Inspect stills directly and selected video spans continuously where possible. Sparse frames cannot certify absence of faces between samples. Native face detection may assist a future bounded inspection workflow but must not be described as complete coverage or identity/privacy certification. Task 9 must retain inspection coverage; tasks 5a, 8, and 12 must block approval/build/delivery for unresolved or revealed faces. The rule is implemented as guidance, not an automatic face detector or hard output gate.

Storyboard guidance now requires explicit review of narration, order, proposed visuals, pacing, sources, rights, and grouped blockers before full production. Native persistent storyboard/approval enforcement remains tasks 5–5a and 8. A material revision requires renewed approval; approval cannot override either visual rule.

**Guidance verification:** `swift build` and `swift test --filter 'ExplainerVisualRulesTests|ExplainerContractsMCPTests|ClipIdentityMCPTests'` passed (9 tests in 3 suites). Tests protect mandatory review and both visual rules. No automatic face inspection, native storyboard UI, or production-gate verification claimed.

## P0 — Trustworthy inputs and planning

### 1. Fix tool discovery and execution contracts

- [x] Make descriptions, schemas, receipts, and actual behavior agree.

**What:** Remove misleading instructions that cause premature stopping, duplicate assembly, or missed capabilities.

**How:**
- Correct `apply_plan`: `commit:false` checks readiness; successful `commit:true` assembles clips and marks the plan applied. Preserve existing shared assembly rather than introduce another operation.
- Advertise local Lottie JSON import in the import contract.
- Reconcile shot-candidate metadata promises with actual receipts. Obtain dimensions and visual evidence through existing inspection paths; do not add synchronous metadata loading to search receipts.
- Honor requested duration and format. Separate reference style from runtime; group genuinely missing decisions instead of silently choosing 30–60 seconds.
- Change long-job continuation instructions only when an owned wait/resume mechanism exists in task 8.

**Start here:** [ToolDefinitions.swift](Sources/CompositorPro/Agent/Tools/ToolDefinitions.swift), [ToolExecutor+Plan.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift), [ToolExecutor+Import.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Import.swift), [ShotCandidates.swift](Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift), [AgentInstructions.swift](Sources/CompositorPro/Agent/Tools/AgentInstructions.swift).

**Done when:** MCP discovery matches execution. An isolated plan assembles once, state readback confirms clips/status, undo restores prior state, and invalid or unchanged requests create no edits or empty undo steps.

**Verified:** `swift build` and `swift test --filter 'ExplainerContractsMCPTests|ShotCandidateBundleTests|PlanEditToolTests|FindShotCandidatesToolTests|ToolExecutorImportMediaTests'` passed (26 tests). New discovery/metadata tests failed before the fix. In-memory MCP verifies readiness-only behavior, one assembly, repeated-call no-op, plan/timeline readback, undo, and invalid-request refusal. Requested duration/format is Agent guidance, not a new automatic duration planner. No UI or live stock-quality verification claimed.

### 2. Turn references into an editorial recipe

- [x] Persist a structured reference recipe that the production plan can use.

**What:** Capture how a film explains its subject, not merely its palette or effects.

**How:**
- Record narrative arc, recurring scene families, typography roles, geographic scale changes, evidence treatment, pacing intent, and available audio observations.
- Attach reference timestamps and inspection coverage. Mark observed, inferred, and unverified properties separately; do not claim motion/audio analysis from thumbnails or captions.
- Separate transferable editorial principles from exact narration, logos, protected assets, voice identity, and sponsorship.
- Accept an externally prepared recipe first. Reuse existing inspection capabilities for supported media; add acquisition only where a concrete input gap remains.
- Keep requested output duration independent of reference duration.

**Done when:** A supplied recipe produces a chapter/scene outline with traceable rationale and truthful limitations, without requiring the user to explain every visual treatment.

**Verified:** `swift test` passed (2,140 tests in 324 suites). Recipe MCP coverage verifies a 90-second authored outline independent of its 21-minute reference, chapter/shot cue citations, limitations, package readback, atomic refusal, no-op, and undo. The Agent authors the outline from supplied analysis; the app does not acquire or automatically analyze reference URLs. See [reference recipe handoff](docs/explainer-reference-recipes.md). UI/storyboard review remains task 5a.

### 3. Add a source and claim ledger

- [ ] Link factual statements to durable evidence and dependent outputs.

**What:** A single reviewed fact should feed narration, charts, and source cards without conflicting copies.

**How:**
- Store stable source/claim IDs, source URL or document reference, publication/access dates, exact supporting passage, values, units, and reviewed/unresolved status.
- Link script paragraphs and graphic data to claim IDs. Keep factual provenance separate from asset licensing.
- Start with user-supplied verified research or a structured handoff from an external research agent. In-app research needs an explicit supported acquisition path before it can be promised.
- Validate duplicate IDs, broken references, missing attribution, non-finite values, incompatible units, and stale evidence. Unresolved publication-critical claims become visible blockers.
- Persist the ledger with its owning production artifacts through existing project-package coordination. Do not create parallel storage or legacy compatibility paths.

**Start here:** [EditPlan.swift](Sources/CompositorPro/Agent/Plans/EditPlan.swift), [EditorViewModel+EditPlans.swift](Sources/CompositorPro/Editor/ViewModel/EditorViewModel+EditPlans.swift), [ProjectPackageCoordinator.swift](Sources/CompositorPro/Project/ProjectPackageCoordinator.swift).

**Done when:** Every displayed factual figure and named location resolves to reviewed evidence. Updating one claim identifies all dependent script and graphic outputs; save/reopen preserves those links.

**Implemented foundation:** `sourceLedger` persists sources, exact passages, quantities/units, review status, and chapter/shot/script-beat claim references with the plan. Changed reviewed research becomes unresolved; dependency receipts identify affected beats and directly or narration-linked chapters/shots. Revision-bound `plan_edit action=review_claims` explicitly confirms current evidence; retries cannot silently approve revised facts. Referenced unresolved claims block assembly. [Ledger contract](docs/explainer-source-ledger.md). This task stays unchecked until tasks 6–7 and 10–12 bind and verify graphic/output consumers.

**Foundation verification:** `swift build`, `scripts/localization/sync.sh`, and `swift test` passed (2,146 tests in 326 suites). Isolated MCP verifies discovery, corrected research/dependency readback, revision-bound review, stale refusal, missing/duplicate claim refusal, repeated-content/review no-ops, assembly blocking, persistence codec, and exact undo. Package coverage rejects malformed saved ledgers. No final-film factual or UI review claimed.

### 4. Anchor scenes to measured narration

- [ ] Extend existing plans with source-linked script beats and narration anchors.

**What:** Resolve scene timing from actual speech instead of asking the model to guess every frame.

**How:**
- Add stable paragraph/beat IDs, editorial purpose, claim references, and scene-to-beat links to the existing plan model.
- Generate or import narration using existing speech operations. Measure duration and align beats using available transcript/alignment capabilities; make unresolved alignment explicit.
- Resolve scene boundaries and reveal/hold times through one shared domain operation. Preserve exact media/frame time and define rounding, overflow checks, and minimum readable holds.
- Key derived timing by script, narration, alignment, and timeline revisions. Do not make authored beat timing and generated clip timing competing sources of truth.
- Own speech/alignment tasks, propagate cancellation, and reject stale results after script, voice, project, or timeline changes.

**Start here:** [EditPlan.swift](Sources/CompositorPro/Agent/Plans/EditPlan.swift), [ToolExecutor+Speech.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Speech.swift), existing transcript and timeline mutation operations.

**Done when:** Changing a paragraph or pronunciation recomputes affected narration timing accurately. Empty speech, failed synthesis, missing alignment, and stale completions cannot silently produce a ready plan.

**Implemented foundation:** Plans own ordered script beats, pronunciation wording, factual links, ready narration sources, and scene-to-beat links. `plan_edit action=measure_narration` measures exact audio duration and conservatively aligns local word timestamps; mismatches remain explicitly unresolved. One shared resolver drives measured readback, readable holds, readiness, and assembly with narration. Revision and source-byte checks reject changed/canceled/stale work; updates invalidate timing, and repeated successful measurements are no-ops. [Timing contract and manual test plan](docs/explainer-narration-timing.md). Automatic paragraph regeneration/resumption belongs to task 8; sub-scene graphic reveal choreography belongs to tasks 6–7. This task remains unchecked until those bindings and real-narration/UI verification are complete.

**Foundation verification:** `swift build`, `swift build --traits BundledSpeech`, `scripts/localization/sync.sh`, and `swift test` passed (2,158 tests in 329 suites). `swift test --sanitize thread --filter 'PlanNarration'` passed (12 tests in 3 suites), with no reported races. Isolated MCP verifies discovery, actual PCM duration loading, measured scene/audio placement, unresolved readback, changed-source refusal, revision invalidation, no-ops, package persistence, and undo. Deterministic lifecycle tests cover cancellation, stale script/timeline/source/file changes, transcription failure, and replacement narration recomputation. Production recognition, audible quality, and manual UI verification remain unverified; fixtures use injected word timestamps.

**Selective-commit verification:** A checkout of only the staged files built and passed 33 focused tests in 10 suites, including narration MCP. Its full suite ran 2,136 tests in 325 suites and failed one unchanged test, `CustomAgentModelPersistenceTests.aRemoteCustomModelWithAStoredKeyIsSelectable` (`route` remained `unavailable`). Unrelated custom-model/credential and finishing changes remain unstaged; the passing working-tree full suite includes those changes. No staged-only full-suite pass claimed.

### 5. Group consequential approvals

- [ ] Combine consequential blockers and script decisions with the required storyboard review rather than ask per-shot questions.

**What:** Ask only for decisions the app cannot safely make: missing evidence, required voice, rights, spending, or publication-sensitive script approval.

**How:**
- Resolve the brief against known project inputs before production; collect unresolved decisions into one actionable review.
- Bind approval to the exact script, claims, selected visuals, and storyboard revision. A substantive change invalidates affected approval rather than silently inheriting it.
- Never authorize paid generation or asset purchases implicitly. Refusal and cancellation leave accurate blocked/canceled state.
- Use localized UI copy and `AppTheme` styling; keep machine-facing approval/status values stable and unlocalized.

**Done when:** A complete supplied-research brief needs no routine shot questions. Full production pauses for storyboard approval, includes any consequential decisions in that review, and resumes only the explicitly approved revision.

### 5a. Review a storyboard before full production

- [ ] Add an editable, persistent storyboard with an explicit approval gate.

**What:** Let the user review the argument, actual proposed visuals, scene order, and pacing before final narration generation, full-resolution graphics rendering, timeline assembly, or export. “Full production” means building the film, not compiling the Swift app.

**How:**
- Derive storyboard cards from existing plan sections/beats and graphic specifications; do not create a competing script or timing model. Each card shows stable scene ID, narration excerpt, purpose, approximate duration, proposed source span, actual asset thumbnail or graphic draft, claim/source links, license, and blockers.
- Generate low-cost graphic drafts and lazy thumbnails off-main with bounded work. Clearly distinguish estimated timing from measured narration timing, and proposed/generated-draft imagery from actual selected source footage. Do not claim an unavailable asset is ready.
- Support scene selection, reorder, replace visual, revise narration, inspect attribution, and grouped comments through shared plan/revision operations and undo. Re-run factual and uniqueness checks after changes.
- Offer a low-resolution sequential preview/animatic using the same scene resolution rules where inputs are available. The storyboard must be reviewable without a full-length render or paid generation; missing previews remain explicit blockers.
- Persist draft, awaiting-review, approved, and stale state with a revision key covering the script, claims, scene order, selected source identity/span, graphic specifications, and timing intent. Do not maintain a second mutable approval owner separate from the production run.
- Pause the run at `awaiting_storyboard_approval`; expose the board and approve/revise actions to both UI and MCP. Approval does not override duplicate or rights blockers.
- After approval, prepare final narration/media and resolve exact timing. Material visual/script/pacing changes require renewed approval; routine timing resolution inside the approved intent is recorded rather than generating needless questions. Revalidate immediately before assembly and export.
- Preserve review state across save, Save As, close/reopen, and cancellation. SwiftUI renders state and forwards actions; all styling uses `AppTheme` and app-owned copy uses `L10n`.

**Start here:** [EditPlan.swift](Sources/CompositorPro/Agent/Plans/EditPlan.swift), [EditorViewModel+EditPlans.swift](Sources/CompositorPro/Editor/ViewModel/EditorViewModel+EditPlans.swift), existing thumbnail/preview services, and task 8's production coordinator. Keep UI and domain code with the owning storyboard/planning feature.

**Done when:** The user can review, revise, and approve every planned scene before full production. An unapproved or stale board cannot start full production; duplicate visuals block approval. MCP state readback proves the reviewed revision matches the run, and manual UI checks cover keyboard focus, Escape, undo, missing previews, and close/reopen.

**Implemented review slice:** `EditPlan.productionRun` owns persistent run/review identity, awaiting-review/approved/stale/canceled phases, exact intent approval, grouped comments, and selection-bound inspection evidence. `prepare_storyboard`, `read_storyboard`, `review_storyboard_scene`, `approve_storyboard`, and `cancel_production` share plan mutations, undo, package persistence, and off-main resolution. Native Storyboard panel derives scene cards, source thumbnails, narration/purpose, estimated versus measured timing, rights, and blockers. Imported library selections now retain license/attribution instead of discarding them. Managed plan assembly rechecks reviewed revision, measured source bytes, uniqueness, full-selection face/suspected-duplicate inspection, and rights. Script/source/span/rights/pacing changes invalidate approval; routine timing resolution does not. [Contract and manual test plan](docs/explainer-storyboard-review.md).

**Still unfinished:** The panel does not itself play video spans or generate semantic drafts/sequential animatics. Inspection evidence is an explicit record of actually performed review, not an automated face/perceptual certificate. Full production coordination, lower-level placement/export protection, actual-output framing/delivery review, lifecycle proofs, and required human UI/playback checks remain tasks 5b–13. This task remains unchecked; generic editing plans are not advertised as verified productions.

**Scene editing slice:** Native scene controls and `revise_storyboard_scene` edit source-linked narration/pronunciation and replacement visual/rights atomically through shared plan mutations. Whole-board known source conflicts refuse the change before undo/mutation. `reorder_storyboard` preserves IDs and durations while moving contiguous scene-owned narration and complete sections together. Ambiguous shared-beat ownership, gaps, overlaps, partial/split sections, stale revisions, unknown sources, and malformed fields are refused. Shared narration edits update all dependent cards; material edits invalidate timing/approval. Human UI verification and sequential preview remain pending.

**Scene editing verification:** `scripts/localization/sync.sh`, `swift build`, and `swift build --traits BundledSpeech` passed. Fixed-source `swift test --filter 'Storyboard|VisualUniquenessTests|PlanEditToolTests|PlanNarrationMCPTests|ExplainerContractsMCPTests'` passed 52 tests in 7 suites; `swift test` passed 2,214 tests in 337 suites; `swift test --sanitize thread --filter 'Storyboard|VisualUniquenessTests'` passed 39 tests in 4 suites without reported races. MCP independently verifies scene order/narration/source readback, atomic replacement, approval revocation, shared-beat updates, pronunciation clearing, refusal/no-op, and undo; AppKit redo is checked through subsequent MCP readback. Deterministic gates cover cancellation and changed run/script/project/timeline/manifest before commit. Direct authored-selection audits now refuse adjacent duplicate still/video selections, while timeline audits retain continuous-split behavior. Native UI/lifecycle and actual-output timing/framing remain pending; an explicit source span currently overrides measured scene duration during assembly and must be resolved in the next slice.

**Scene editing selective verification:** Isolated staged-only snapshot built and passed 51 focused tests in 7 suites. Its first full run executed 2,192 tests in 333 suites and failed only unchanged `CustomAgentModelPersistenceTests.aRemoteCustomModelWithAStoredKeyIsSelectable` (`route != .direct`), previously observed in earlier snapshots. The test selects the custom model after its wait loop; the working-tree correction and credential changes predate this slice and remain unstaged. On the identical snapshot, `swift test --filter 'CustomAgentModelPersistenceTests'` passed 9 tests in 1 suite and repeated `swift test` passed 2,192 tests in 333 suites. This is a staged-only full pass, not a fix for the intermittent unrelated routing test.

**Review verification:** Latest fixed-source `swift build`, localization sync, and `swift build --traits BundledSpeech` passed. Focused MCP/domain run passed 44 tests in 6 suites; `swift test` passed 2,206 tests in 336 suites; `swift test --sanitize thread --filter 'Storyboard|VisualUniquenessTests'` passed 31 tests in 3 suites with no reported races. Coverage independently verifies discovery, blockers, stale approval, copied/changed sources, retained unchanged inspections, measured readback, assembly retry, package codec, cancellation, and undo. Earlier timing assertions failed while source/tests were being edited during a build; latest fixed-source runs pass, but no cause beyond that observed mismatch is established. Human UI, full-span/final-framing inspection, real speech recognition, and Save As/close/quit verification remain pending.

**Review selective-commit verification:** Isolated staged-only snapshot built, passed 43 focused tests in 6 suites, and passed its full suite (2,184 tests in 332 suites). The extra working-tree focused test belongs to unrelated finishing work, which remains unstaged. No fixes to the previously intermittent custom-model routing test are inferred from this pass. Native UI and installed-app verification remain unperformed.

### 5b. Enforce the no-repeat visual rule

- [ ] Add shared, mandatory visual-uniqueness validation to planning, assembly, revisions, and delivery.

**What:** Prevent the same image/video from appearing twice even when it has different clip IDs, download URLs, crops, trims, or wrappers. A prompt instruction alone is insufficient.

**Timeline identity fix:** Repeated IDs in one `move_clips` request previously appended multiple copies with the same clip ID. Shared move validation now refuses repeated IDs before mutation/undo, including full and short IDs resolving to the same clip through MCP. Placement still creates distinct clip IDs while retaining the original `mediaRef`; source identity is a separate concern. `swift build`, localization sync, and working-tree `swift test` passed (2,161 tests in 330 suites). Regression tests reproduced the original duplication through domain and MCP calls, verify unchanged timeline/undo on refusal, and verify valid movement and exact undo. Manual UI check: place one asset twice, move either placement, undo, and confirm independent selection; repeated media use remains prohibited for the finished explainer, not for general editing experiments.

**Media identity foundation:** Imported/prepared bytes now have a stable SHA-256 `inputId`, independent of library `mediaRef` and placement `id`. Inventory, inspection, timeline/mutation receipts, and candidates expose it. Search hits retain provider/source identity through import and manifest persistence; alternate renditions can share `origin.sourceId`. Hashing is serial, off-main, cancellation-aware, metadata-validated, and bounded to 64 cache entries. Restore/relocation require revalidation; relink invalidates prior identity/provenance. Byte imports await preparation and report failed records instead of false readiness. Persisted request/source-page URLs omit credentials, queries, and fragments. [Identity contract and manual checks](docs/explainer-media-identity.md).

**Foundation verification:** Working-tree `swift build`, `swift build --traits BundledSpeech`, and `swift test` passed (2,173 tests in 333 suites). Final `swift test --sanitize thread --filter 'MediaInputIdentity|PlanNarration|ShotCandidateBundleTests|ToolExecutorImportMediaTests'` passed (35 tests in 7 suites), including an additional corrupt-byte MCP regression; no reported races. Isolated MCP independently reads inventory/timeline state, checks distinct placements/shared inputs, manifest persistence, invalid-origin refusal, corrupt import failure, and undo. Focused lifecycle tests cover cancellation and relink-away-and-back stale completion. These are identity/provenance foundations, not perceptual matching, frozen derivative lineage, hard uniqueness/face gates, or storyboard approval. Manual UI, real-stock download, and full Save As/close/quit checks remain pending.

**Identity selective-commit verification:** The staged-only snapshot built and passed 41 focused tests in 9 suites. Its full suite ran 2,152 tests in 329 suites; the only failure was the previously observed, unchanged `CustomAgentModelPersistenceTests.aRemoteCustomModelWithAStoredKeyIsSelectable` (`route == .direct`). Unrelated credential/custom-model and finishing work remains unstaged; no staged-only full-suite pass claimed.

**Output occurrence foundation:** `qc_timeline.visualIdentity` now audits retained hashes/provider aliases over an immutable output snapshot off-main. It expands nested carriers through shared `NestFlattener`, retains stable child-lane identities, includes overlays, excludes hidden lanes/linked audio, and joins only uninterrupted same-library source runs. Renamed copies, alternate renditions, disjoint trims, replayed carriers, and simultaneous uses produce source-level conflict receipts with root-output ranges. Missing identity/media, unknown derivative lineage, malformed timing/IDs, nesting cycles, and traversal limits remain unresolved. Cancellation and timeline/manifest/project changes reject stale reports. [Occurrence contract](docs/explainer-visual-occurrences.md). This is not yet the mandatory gate: QC structural `pass` is separate, `deliveryVerified` is always false, and freshness/perceptual/face checks remain unperformed. Storyboard/assembly/export enforcement and provisional assignment filtering remain unfinished; task 5b stays unchecked.

**Occurrence verification:** Final working-tree `swift build`, `swift build --traits BundledSpeech`, and `swift test` passed (2,195 tests in 334 suites). `swift test --sanitize thread --filter 'VisualUniquenessTests|QCTimelineToolTests|MediaInputIdentityMCPTests'` passed (37 tests in 3 suites), with no reported races. The staged-only snapshot built, passed the same 37 focused tests, and passed its full suite (2,173 tests in 330 suites). Earlier staged-only runs exposed an unchanged custom-model routing test failure; this passing run does not establish that intermittent test is fixed. Coverage includes transitive aliases, continuous/replayed splits, copied-file MCP conflict readback, simultaneous/nested overlays, trimmed carriers, missing inputs, invalid ranges/speeds, cycles, 10,000 continuous splits, cancellation, stale revisions, and unchanged timeline/undo after review. Manual UI and continuous-render comparison remain pending.

**How:**
- Preserve canonical origin identity through search → import → derivative rendering → placement: original provider plus original asset ID/source page, local content fingerprint, and derivative input lineage. Aggregator IDs such as Pexafy's `photo_id` must also resolve to the underlying original source identity.
- Compute content hashes off-main at import/preparation boundaries; cache by validated asset revision rather than read files during timeline interaction or every export check. Provider identity catches different renditions; hashes catch identical local copies. Unknown identity is unresolved, not proof of uniqueness.
- Keep one authoritative occurrence calculation over an immutable snapshot of the target output. Expand nested timelines and repeated sequence carriers, include background/overlay/composite inputs, and inspect looping/repeated visual playback. Reject cycles and invalid timing before arithmetic.
- Count source uses, not candidate spans. Two different ranges of the same source video still violate this rule. An editorial split that preserves one uninterrupted source/timeline run is one occurrence; disjoint, replayed, or simultaneous placements are multiple occurrences. A replacement render at the same occurrence is not an additional use.
- Filter already-used and provisionally assigned sources from shortlists before selection. Validate the whole proposed assignment atomically to catch two scenes choosing the same new asset concurrently; cancellation/replacement releases provisional assignments.
- Use the same validator for storyboard approval, plan readiness/assembly, Agent visual placement/duplication, section revisions, and Agent-produced export preflight. Recheck the current output snapshot, not just the original plan, so manual edits and later imports cannot evade the final must-check.
- Return a structured report with coverage, unresolved identity, canonical source, conflicting scene/clip IDs, output time ranges, and replacement action. Block approval/build/delivery until violations are removed; do not downgrade repeats to warnings or add a silent bypass.
- Detect likely cross-provider/re-encoded copies with a bounded perceptual image/video fingerprint pass during preparation. Treat similarity as a review signal, not infallible proof; unresolved suspected duplicates block delivery until resolved. Do not claim hashes alone detect all crops or independently edited copies.
- Test same asset twice, distinct trims, renamed copies, alternate resolutions, transformed derivatives, repeated nested carriers, loops, duplicate images inside composites, unknown provenance, and concurrent assignments. Also test distinct assets passing, one continuous split passing, cancellation, replacement, undo, and stale validation rejection.

**Start here:** [ShotCandidates.swift](Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift), [StockMedia.swift](Sources/CompositorPro/MediaSources/StockMedia.swift), existing import/provenance and timeline traversal, [ToolExecutor+Plan.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift), and [ToolExecutor+Export.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Export.swift). Domain validation has one owner shared by all callers.

**Done when:** An isolated Agent production cannot approve, assemble, revise into, or deliver duplicate image/video uses. Validation independently reads all output occurrences and returns zero duplicates with no unresolved identity/similarity cases. Tests verify refusal leaves timeline and undo unchanged.

## P1 — Semantic scenes and reliable execution

### 6. Build editable geographic scenes

- [ ] Add a narrow map-scene operation with geographic semantics.

**What:** Create accurate locator, industrial-hub, and relationship maps whose labels stay attached during camera changes.

**How:**
- Accept places, regions, firm locations, meaningful connections, claim references, narration anchors, and style intent.
- Start with one projection and sourced geographic dataset. Support mainland and island Malaysia; reject ambiguous or unresolved locations.
- Own coordinate conversion, region highlights, pins, routes, camera framing, reveal order, and label collision handling in one feature.
- Distinguish illustrative relationships from sourced quantitative flows. Geography and claims remain independent of styling.
- Generate editable specifications plus playback/export media using existing graphics machinery where suitable. Camera movement must transform map geometry and attached labels together.
- Reuse vector geographic data and style, not an already-used image/video asset. Each separate map scene needs its own authored content and unique media inputs; task 5b checks raster backgrounds and baked/composite lineage too.

**Done when:** A Penang/Kulim/regional map remains geographically correct through zooms and successive reveals. Correcting a place changes only dependent scenes; continuous playback confirms legibility and attachment.

### 7. Build sourced data and evidence scenes

- [ ] Support a small typed graphic family instead of decorative generated charts.

**What:** Create comparison charts, numeric comparisons, source cards, and dated policy timelines from real structured inputs.

**How:**
- Begin with a sourced numeric comparison and source card for the first release. Add a comparison line chart and policy timeline after that complete slice works.
- Store series/events, units, dates, source/claim IDs, quotations or marked paraphrases, annotations, and reveal anchors separately from styling.
- Compute axes, scales, chronology, layout, and holds deterministically. Reject malformed data, incompatible units, unsupported combinations, and fabricated attribution.
- Reuse text, layout, and motion operations internally; do not require an Agent call for every label or keyframe.
- Validate display/narration agreement, including GDP versus GDP per capita, nominal versus adjusted values, and announced versus realized investment.

**Done when:** A corrected value updates narration and dependent graphics without leaving the old value elsewhere. Labels and citations are readable at delivery resolution; invalid data produces actionable failures before mutation.

### 8. Own the complete production lifecycle

- [ ] Add one persisted production coordinator around existing services.

**What:** Carry a brief through asynchronous preparation, assembly, finishing, review, and verified delivery without user continuation prompts.

**How:**
- Persist run ID, project/timeline identity, referenced artifact revisions, phase, approvals, owned job handles, blockers, review coverage, and terminal receipt. Do not duplicate authored scripts or graphic data in run state.
- Implement the smallest complete phase flow: inputs/script → proposed visuals and graphic drafts → uniqueness-checked storyboard → explicit approval → final narration/timing and assets/graphics → validated assembly → finishing/review → uniqueness-checked export/output verification.
- Resume matching phases on job completion. Deduplicate completions, expose cancellation, and bound retries; do not busy-poll or keep undo groups open across waits.
- Revalidate identity, revision, and cancellation after every await. Close/reopen re-resolves artifacts and jobs; Save As and close must respect admitted package mutations and reject late commits.
- Bound downloads, decoders, speech, graphics preparation, and renders separately. Keep expensive execution off the main actor.
- Return explicit completed, failed, blocked, or canceled outcomes with partial-work details. For external MCP clients expose durable inspect/wait behavior rather than assume automatic conversation resumption.

**Start here:** [AgentService.swift](Sources/CompositorPro/Agent/Chat/AgentService.swift), existing import/generation jobs, [ToolExecutor+Plan.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift), [ExportQueue.swift](Sources/CompositorPro/Export/ExportQueue.swift), [ProjectPackageCoordinator.swift](Sources/CompositorPro/Project/ProjectPackageCoordinator.swift).

**Done when:** One brief plus required storyboard approval reaches a verified export without “continue.” Unapproved/stale storyboards and repeated visuals block progression. Failure, duplicate completion, cancellation, project switch, Save As, and close/reopen never commit stale work or report misleading success.

### 9. Acquire verified visual coverage

- [ ] Reuse search and import within an owned coverage-preparation workflow.

**What:** Select suitable licensed footage without repeatedly making the user coordinate search, download, inspection, and readiness.

**How:**
- Produce a bounded shortlist using existing visual, spoken, and catalog retrieval. Inspect actual imagery before choosing coverage.
- Exclude sources already used or assigned within the output, retain pagination, and prioritize relevant unique alternatives. Do not repeatedly take the first popular result or prefer an imported duplicate merely because it is ready.
- Classify assets as direct evidence, contextual illustration, archival evidence, or explicit diagram. Generic factory footage must not impersonate a named company or prove a location.
- Preserve source spans, license, attribution, evidence references, and stable asset IDs; reuse existing import and placement rules.
- Wait for usable imported media through task 8. Reject unsupported or offline assets, surface failures, and request replacement only when the intended scene cannot be fulfilled.

**Start here:** [ShotCandidates.swift](Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift), [ToolExecutor+Import.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Import.swift), existing search/inspection operations.

**Done when:** The production obtains usable unique coverage with honest provenance. Failed downloads, exhausted unique candidates, and unavailable assets produce explicit blockers or reviewed replacements, not false readiness or silent reuse.

### 9a. Improve source diversity without replacing providers blindly

- [ ] Fix selection diversity and evaluate complementary sources using the existing provider seam.

**What:** Solve repeated-stock selection at retrieval and assignment, then add sources for coverage they actually provide. More catalogs alone do not guarantee better footage or no duplicates.

**Provider findings — public documentation checked 2026-11-08:**
- **Pexafy:** Its documented product is semantic **photo search**, aggregating nine libraries including Unsplash, Pexels, and Pixabay. REST/MCP support may improve descriptive still-image discovery, but no video-search API was found in the inspected docs; it is not a demonstrated replacement for Pixabay footage. Free plan lists 5,000 API requests/month and 20/minute, with limited results. Source assets retain their original platform licenses. Search relevance, generated descriptions, and a `free` flag do not certify location, date, factual accuracy, or model/property rights.
- **MediaWiki versus Wikimedia Commons:** `mediawiki.org` documents wiki software, not a stock-media catalog. The relevant repository is **Wikimedia Commons**, accessed through its MediaWiki API. Prefer evaluating it for identified places, historical images, portraits, diagrams, and documentary material; this is an editorial-fit recommendation, not measured superiority for cinematic B-roll. Commons also contains video, but individual formats, resolution, and licenses require validation. It is not a drop-in equivalent of a commercial stock-video API.
- **Pixabay:** Still provides a documented image/video API; this app currently implements its video provider. It supports `page` and `order` (`popular` by default, or `latest`), yet the current provider omits both and keeps the first usable results. API docs require 24-hour request caching, prohibit systematic mass downloads, and caution against excessive automated querying; implement bounded user-intent searches consistent with those terms, not catalog harvesting.
- **Existing alternatives:** Pexels photo/video support and Openverse image/audio support already exist in source. Use configured/available sources and truthful per-provider outcomes before adding an overlapping integration. Verify current Pexels access policy rather than treat older source comments as current provider policy.

**Observed repetition risks, not a reproduced root cause:** [PixabayProvider.searchURL](Sources/CompositorPro/MediaSources/PixabayProvider.swift#L43) has no pagination/order; [StockMediaSearch](Sources/CompositorPro/MediaSources/StockMedia.swift#L248) deduplicates only download URLs within a response; [ShotCandidateBuilder](Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift#L112) has no output-usage input and prioritizes ready library rows over remote rows. Different source spans remain distinct candidate IDs. These paths can keep surfacing the same imported/popular media; changing providers does not supply missing usage memory.

**How:**
- Extend existing retrieval with canonical exclusions and bounded page/cursor continuation; filter before final limits so used hits do not starve the shortlist. Translate scene-specific intent into each provider's supported query/filter model rather than send one generic query everywhere.
- Rank relevant eligible candidates for diversity across subject, framing, creator, and source. Never sacrifice factual fit or license safety merely to get a new clip; switching from video to a still/diagram changes the storyboard and requires review.
- Separate two concerns: within-video reuse is a hard block under task 5b; reuse across different productions is a novelty-ranking concern. Keep a bounded local recent-output usage history, updated only for successful deliveries, so new videos do not automatically receive the same top stock clips. Do not invent a global permanent ban across all projects.
- Benchmark fixed briefs with current sources first, including repeated runs: unique eligible hits, scene relevance, overlap between outputs, usable resolution/container, import failures, licensing completeness, latency, requests, and cost. Inspect actual returned media; random selection is not a quality strategy.
- Evaluate Commons stills first for this documentary use case. Reuse `StockMediaProvider`, `StockMediaHit`, and existing import/staging. Query the Commons endpoint, search file records with continuation, then fetch bounded selected-file metadata: canonical file/page identity, original URL, revision timestamp/hash, MIME/dimensions, and license/author/credit details. Sanitise untrusted HTML metadata; do not equate uploader with creator or assume an embedded Wikipedia fair-use image is a Commons asset.
- Honor per-file attribution and license obligations, including ShareAlike/adaptation conditions where applicable. Reject unresolved rights; never imply all Commons files share one blanket license. Validate AVFoundation/container support or an explicit conversion path before advertising Commons video readiness.
- Evaluate Pexafy only for a still-image gap. Preserve its own ID plus underlying source ID/page, URLs, dimensions, credit, and definitive original license. Respect plan limits, pagination, quota/rate errors, and credential security; do not silently upgrade to a paid plan. Add it only if the benchmark justifies dependency and quota costs.
- Reconcile cross-provider copies by canonical original source and fingerprints, including Pexafy returning an image already found through Pexels/Pixabay/Openverse. Report searched/skipped/failed providers and whether more eligible pages exist.

**Start here:** [StockMedia.swift](Sources/CompositorPro/MediaSources/StockMedia.swift), [PixabayProvider.swift](Sources/CompositorPro/MediaSources/PixabayProvider.swift), [PexelsProvider.swift](Sources/CompositorPro/MediaSources/PexelsProvider.swift), [OpenverseProvider.swift](Sources/CompositorPro/MediaSources/OpenverseProvider.swift), [ShotCandidates.swift](Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift), and existing credentials/settings/runtime-capability reporting.

**Sources:** [Pexafy overview](https://docs.pexafy.com/), [photo-search API](https://docs.pexafy.com/api-reference/search/search-photos-by-text), [plans](https://docs.pexafy.com/plans), [source licenses](https://pexafy.com/legal/licenses/), [MediaWiki overview](https://www.mediawiki.org/), [Commons reuse requirements](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia), [file metadata API](https://www.mediawiki.org/wiki/API:Imageinfo), [Pixabay API](https://pixabay.com/api/docs/).

**Done when:** Representative briefs yield relevant unique coverage without repeatedly choosing page-one/imported duplicates. Cross-output overlap is measured and reduced without degraded relevance. Any added provider proves canonical identity, licensing, pagination, failure handling, and isolated import/MCP integration; no unverified video support is advertised.

### 10. Preserve editable graphic artifacts

- [ ] Store original graphic specifications alongside bounded rendered derivatives.

**What:** A baked clip supports playback, but a factual or stylistic correction must not require reconstructing the entire scene.

**How:**
- Persist scene IDs, source data/claim links, geometry, styling, narration anchors, and renderer version in the owning graphics feature.
- Preserve all image/video input lineage in derivatives so rendering, cropping, or compositing cannot bypass task 5b's uniqueness check.
- Key renders by complete specification and relevant timing/configuration revisions. Define cache capacity, invalidation, replacement, cleanup, and lifecycle behavior.
- Reuse Lottie when it meets the semantic contract; do not have the model author arbitrary large JSON for every scene.
- Audit current Lottie rendering before scaling: frame rendering, writer setup, cancellation, and memory must have explicit background execution and bounded resource use.
- Stage complete outputs and install through package coordination. Cancel or reject stale replacement renders without deleting the latest successful media.

**Start here:** [LottieVideoGenerator.swift](Sources/CompositorPro/Preview/LottieVideoGenerator.swift), [ToolExecutor+Import.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Import.swift), [ProjectPackageCoordinator.swift](Sources/CompositorPro/Project/ProjectPackageCoordinator.swift).

**Done when:** Correcting one label regenerates only affected derivatives. Playback/export reference the current successful revision; cancellation and render failure preserve valid prior output without claiming the correction succeeded.

### 11. Make section revisions dependency-aware

- [ ] Resolve one editorial change across all dependent outputs as one coherent action.

**What:** “Shorten the Penang explanation” should not require separate prompts to repair speech, maps, captions, music, and downstream placement.

**How:**
- Use stable section/beat/scene IDs and explicit dependencies to calculate the affected set.
- Prepare changed narration and graphics before mutation. Resolve timing, reveals, source cards, music, captions, and downstream positions through shared operations.
- Preserve unrelated content and IDs. Detect manual overrides, locked tracks, linked clips, and nested-timeline constraints; refuse or surface conflicts instead of silently overwriting them.
- Confirm revisions are still current, then commit one undoable section change. Undo restores exact authored and resolved state without cumulative rounding.
- Revalidate visual uniqueness and storyboard approval after changing selected media, scene order, script, or material pacing. New duplicates block the entire revision before commit; material changes return to storyboard review.
- Define no-op and repeated-request behavior. Failed/canceled preparation must not partially retime the live timeline.

**Depends on:** Tasks 3, 4, 8, and 10.

**Done when:** A statistic correction and section shortening update all dependencies, preserve unrelated sections, and undo exactly. Concurrent user edits and cancellation cannot create partial revisions.

## P2 — Quality proof and measured scaling

### 12. Review facts, motion, audio, and coverage

- [ ] Extend current finishing review with evidence-aware checks and explicit inspection coverage.

**What:** “Exported” is not the same as “reviewed.” Six sampled stills cannot certify routes, camera motion, reveal timing, or speech seams.

**How:**
- Reuse current encoded review and audio finishing; do not reopen older audio defects as missing without testing the updated implementation.
- Add structural checks for missing media, blank intervals, exact timing, orphaned dependencies, and delivery settings.
- Run the mandatory visual-uniqueness report against the actual output snapshot, including nested/composite inputs. Missing provenance, unresolved suspected duplicates, or repeated visual occurrences block Agent delivery.
- Compare claims with script, displayed figures, chart units, dates, locations, and coverage classification.
- Analyze short moving ranges around dense reveals and transitions using a supported temporal inspection path; require human playback where automated capability is absent.
- Check narration completeness, seams, loudness, clipping, and speech/music relationship. Distinguish measured sample peak from true peak.
- Persist requested versus successfully inspected intervals/modalities, failures, and unresolved issues. Make bounded repairs through shared domain operations and recheck affected ranges.

**Start here:** [ToolExecutor+ReviewTimeline.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+ReviewTimeline.swift), [RenderedTimelineReview.swift](Sources/CompositorPro/Preview/RenderedTimelineReview.swift), [local-finishing.md](docs/local-finishing.md).

**Done when:** Reports never claim unseen motion or unheard audio passed. Independent output inspection confirms actual delivery; unresolved factual or temporal defects remain visible.

### 13. Add intent-level Agent operations

- [ ] Expose production, scene creation, section revision, and durable inspection at user-intent boundaries.

**What:** Let the Agent request coherent filmmaking outcomes without reproducing application orchestration.

**How:**
- Define representative requests and receipts before schemas: produce an explainer, inspect/revise/approve a storyboard, build a map/data scene, revise a section, and inspect/wait/cancel production.
- Accept stable IDs and filmmaking concepts, not storage paths, track indexes, or implementation modes.
- Keep narrow editing tools available. New operations wrap shared domain workflows; they do not duplicate assembly, timing, package, or undo logic.
- Validate the full request before mutation. Receipts include changed IDs, timing changes, no-op state, warnings, blockers, and durable terminal results.
- Include storyboard revision/approval and uniqueness coverage/conflicts in production inspection. No tool may bypass approval or the no-repeat validation by using a lower-level placement/export path.
- Verify tool discovery, schemas, positive/negative cases, async completion, persistence, and undo through an isolated MCP project with independent state readback.

**Done when:** One representative brief and one section-revision request achieve their stated outcomes through MCP, without hidden low-level orchestration requirements or success-shaped failures.

### 14. Measure long-form efficiency and responsiveness

- [ ] Optimize only after the complete narrow workflow is proven.

**What:** Preserve argument continuity and responsiveness as productions grow, without substituting token reduction for quality.

**How:**
- Keep project-wide constraints compact and section-local working context focused. Use task-relevant tool discovery and concise receipts rather than resend unrelated detail.
- Prepare independent assets with bounded concurrency; serialize conflicting mutations. Audit main-actor graphics work before large workloads.
- Measure fixed comparable briefs: user messages, internal calls, tokens, time to first playable cut, time to verified export, repairs, manual interventions, factual defects, and peak memory.
- Use Instruments or focused benchmarks for rendering and responsiveness. Record before/after workloads and results; do not claim improvements from architectural changes alone.
- Revisit existing plan size limits only when a representative documentary proves they are insufficient; do not increase bounds speculatively.

**Start here:** [AgentService.swift](Sources/CompositorPro/Agent/Chat/AgentService.swift), [EditPlan.swift](Sources/CompositorPro/Agent/Plans/EditPlan.swift), [LottieVideoGenerator.swift](Sources/CompositorPro/Preview/LottieVideoGenerator.swift).

**Done when:** Measured 18–21-minute workloads preserve section continuity, bounded memory/resources, recovery, and truthful full-output review coverage.

## Release gates

Priorities describe importance, not isolated batches. Build the smallest end-to-end subset of each required layer before expanding it.

### Gate A — 90-second landscape proof

- [ ] Fix discovery contracts; use supplied verified research, licensed footage, one narrator, one locator/route map, and one sourced comparison.
- [ ] Complete brief/script → unique proposed visuals/graphic drafts → storyboard review and explicit approval → final narration/timing/assets → validated assembly → finishing/review → verified export, with no sponsor or paid generation.
- [ ] Achieve one complete brief plus grouped storyboard approval and zero continuation prompts. Reapproval is required only for material changes, not routine job completion.
- [ ] Prove unapproved/stale boards cannot start full production and zero duplicate image/video uses are present in the final output. Check copied files, alternate renditions/trims, nested timelines, loops, and composite inputs.
- [ ] Confirm factual/display agreement, geographic attachment, readable holds, correct export settings, and full human playback with sound.
- [ ] Stop expanding scope until this gate passes; detailed charts, policy timelines, and autonomous research can follow.

### Gate B — 3–5-minute chaptered explainer

- [ ] Reuse map data/style across multiple sections and regions without reusing image/video assets; add comparison charts and policy timelines as needed.
- [ ] Revise and reapprove the storyboard; replace a rejected visual with a unique licensed candidate and preserve unrelated scene approvals.
- [ ] Correct pronunciation and a statistic; shorten a section; verify dependent updates and exact undo.
- [ ] Exercise failed asset preparation, cancellation, duplicate completion, concurrent user edit, save/autosave, Save As, and close/reopen.
- [ ] Add external research acquisition only with explicit source verification and rights contracts.

### Gate C — 18–21-minute documentary

- [ ] Benchmark long-context continuity, incremental regeneration, full-output review, rendering responsiveness, and bounded memory/cache use.
- [ ] Verify recovery across interruptions and independently inspect the completed output.
- [ ] Compare prompt count and production quality against the same fixed brief before claiming reference-level readiness.
- [ ] Run repeated briefs to measure cross-output stock overlap; keep per-video duplicate count at zero. Verify provider quotas/terms under bounded user-intent workloads.

## Verification for implementation work

- [ ] Run focused regression tests while iterating; run `swift build` after source changes.
- [ ] Run `swift test` for changes to core editing, persistence, undo, concurrency, or shared infrastructure.
- [ ] Run `swift build --traits BundledSpeech` for speech, transcription, MLX, or bundled-model changes; verify builds with and without the trait.
- [ ] Use deterministic concurrency tests for waiting, cancellation, stale completion, and teardown; apply concurrency diagnostics or Thread Sanitizer where appropriate.
- [ ] Exercise changed Agent tools through MCP on an isolated project and non-conflicting port. Read state back and inspect persistence/undo independently.
- [ ] Cover storyboard approval/staleness and duplicate blocking through MCP, plus a fake-provider regression proving pagination/exclusions avoid repeated top hits. Keep unit tests offline; live provider comparisons are separate opt-in benchmarks.
- [ ] Provide a manual UI plan covering playback, keyboard/mouse, Escape, focus, undo, empty/disabled states, and affected lifecycle paths. UI passing requires user confirmation.
- [ ] Report exact commands/results and remaining blockers. Do not mark an item complete based solely on source presence or a successful tool receipt.

## Signed app update

- [ ] After implementation and repeated deep verification, build the release app with Developer ID signing, verify its signature/resources, and safely replace the existing installation.
- [ ] Preserve the current app until the complete signed replacement is ready; never substitute an ad-hoc build for the requested signed release.

**Preflight (2026-11-08):** Existing installation is `/Applications/CompositorPro.app`, bundle ID `io.compositor.pro`, version `0.7.6`. `security find-identity -v -p codesigning` returned `0 valid identities found`. Developer ID certificate and matching private key must be restored or unlocked through Keychain Access before signing. The bundle script's default `scripts/Palmier_Pro_Developer_ID.provisionprofile` is also absent; configured overrides were not inspected. No release signing, app replacement, or installed-runtime verification performed. Implementation, full production gates, and manual UI review remain incomplete.

**Repeated signing preflight:** Still `0 valid identities found`. No `SIGNING_IDENTITY`, `PROVISION_PROFILE`, or `NOTARY_PROFILE` environment override is configured, and no repository `.provisionprofile` exists. Signed release remains blocked; the installed app remains untouched.
