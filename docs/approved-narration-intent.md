# Approved narration intent

`EditPlan.narrationIntent` owns authored language, start frame, and narrator selection. `EditPlan.narration` contains only the attached audio `mediaRef`. `ProductionRun.approvedRevision` remains the sole approval owner.

Both storyboard revision hashing and approval invalidation use `EditPlan.storyboardIntent`. Attachment, timing, and narration measurement revision are not storyboard intent. Script, pronunciation, language, placement, exact speech voice/engine/rate/pitch, and explicitly chosen recording identity are material changes.

## Tool input

Create or update a plan with:

```json
{
  "narrationIntent": {
    "language": "en-US",
    "startFrame": 0,
    "narrator": { "kind": "recording", "mediaRef": "existing-ready-audio" }
  }
}
```

The domain measures the selected recording's actual bytes through `MediaInputIdentityService` before committing intent. Caller-supplied hashes and byte counts are not accepted. Persisted intent includes the chosen recording reference and measured identity; readback exposes both. The chosen reference locates the explicitly supplied recording, independently of the eventual attachment reference.

Local speech input uses `kind: "local_speech"`, `engine: "system" | "piper"`, exact `voiceIdentifier`, and explicit `rate` and `pitch` multipliers from 0.5 through 2. System identifiers must match an installed voice and its exact language. Piper identifiers must match an installed model, language, executable, and readable model/configuration files; their byte identities are measured into intent. Piper requires pitch 1. Missing/unknown choices are refused, never substituted. This operation only resolves intent; it does not synthesize, download, install, or spend credits.

Attach a source separately:

```json
{ "narration": { "mediaRef": "existing-ready-audio" } }
```

`NarrationSource` no longer accepts language or start frame. Generic plans may specify language/placement without a narrator and remain unrestricted audio edits. Managed narration attachments must match the selected recording byte identity. An explicit alias containing the same bytes is eligible; a different recording requires a material intent change and fresh approval.

## Eligibility and undo

`EditorViewModel.preparePlanNarrationChange` resolves/validates immutable candidate state. Its scoped validation is required by `changeEditPlans` for narrator selection and managed attachment changes. Raw UI or Agent plan updates cannot skip that gate. `setPlanNarrationIntent` and `attachPlanNarration` share this path and `EditorUndo`; validation occurs before undo registration, with no undo groups spanning awaits.

At asynchronous boundaries, validation rechecks plan/run, project/timeline revision and geometry, selection, source object/preparation context/identity/type/duration, availability, and cancellation. Preparation context includes the source URL and unique source revision, generation job/output/status, and import input. Restoring the original URL and byte identity after relinking does not restore the observed source revision. Failed, canceled, stale, and unchanged operations do not create undo entries. A matching first attachment invalidates old narration timing, not storyboard approval. Measurement checks current recording bytes before and after alignment and rejects a timing fingerprint from different bytes at commit; assembly and measured preview independently verify the current source. Recording review context remains validated after later visual-source awaits.

Storyboard readback exposes `narrationIntent`, `approvalBlockers`, and `canApprove`. Approval requires complete available narrator intent and existing visual/claim/rights checks; it does not require an audio artifact. `blockers` and `canProduce` additionally require current attachment identity and resolved timing. Final playback coverage can block production without changing the approved authored revision.

## Deliberately unavailable speech attachment

Exact generated speech attachment proof is not implemented. Every managed local-speech attachment is refused, and `unverified_synthesized_narration` prevents production readiness. Generic speech receipts, filenames, `GenerationInput`, and package JSON are not synthesis proof. No receipt signer, alternate approval owner, dummy media reference, approval bypass, or compatibility mapping is introduced.

Actual pinned synthesis depends on the package/import lifecycle: complete off-main rendering and media preparation, operation admission through install/finalization/state commit, project/approval revalidation, cancellation cleanup, and coordinated save/Save As/close. This slice does not claim that workflow exists.

### Pinned synthesis implementation contract

The next operation is one coherent **Prepare Approved Narration** action. MCP supplies only plan/run/approved-revision identifiers; the domain reads exact script wording, pronunciation, language, placement, engine, voice, rate, and pitch from approved intent. Generic `generate_speech` remains unchanged and cannot supply managed proof.

Use a strict rendering seam sharing existing speech queues/writing/chunking. It must refuse engine/voice/language substitutions, bypass prosody delivery multipliers, preserve exact Piper rate arguments, and render from private model/config copies matching approved identities. Record applied engine controls, submitted text digests, written sample frames, inserted silence, and a fixed delivery version. Cancellation must drain callbacks/processes before deleting output; incompatible or missing chunks fail instead of silently shortening speech.

Persist app-owned derived `NarrationSynthesisProof` with the plan, outside `storyboardIntent`: operation/request digest, plan/timeline/run/approved revision, final narration revision, actual engine/voice/language/control evidence, pinned model/config identities, and installed media reference/byte identity. The renderer supplies execution evidence; the domain binds installed bytes. No caller accepts proof or self-attested hashes. This is execution provenance, not acoustic certification or protection against deliberately edited project JSON.

Prepare render, unpublished metadata/identity, measured timing, and prospective plan state before publication. Verify installed destination bytes inside transaction-owned cleanup, then publish media/manifest/attachment/proof/timing synchronously under one shared undo action. `changeEditPlans` currently rotates narration revision and clears timing on attachment; allocate the final revision once and validate prospective state rather than chaining attachment and measurement as separate actions. Shared undo grouping does not roll back partially applied throwing mutations.

Require current approval and approval blockers, not `canProduce`, before synthesis; missing narration would otherwise create circular eligibility. Revalidate attempt generation, project/timeline/source/selection/run/approval after every await. Derived attachment/proof/timing preserve approval. Authored pronunciation or voice changes revoke it. Whole-intent ownership must span render through cleanup; do not hold a package lease during synthesis/alignment or make ordinary saves wait for the tool's own intent.

A verified existing output is a byte-readback no-op. Recognition mismatch may commit meaningful output/proof with explicitly unresolved timing and a blocked partial receipt; retry measures the same output rather than resynthesizing. Exceptions/cancellation/stale results publish nothing and add no undo. Interrupted attempts remain inspectable under the existing production run; automatic paid retry is outside this local workflow.

Required proof: strict delivery and model-copy tests; proof/input/output tampering; canceled/stale/ABA attempts; exactly one revision and undo/redo; save/Save As/close interleavings; actual MCP approve → synthesize → independent package/WAV readback → assembly → undo/redo. Real audible quality and recognition remain human/provider verification, separate from injected timestamp fixtures. This contract is planned, not implemented or verified.

## Narration schema and instruction integration

- `ToolDefinitions.swift` exposes shared `narrationIntent` in both `plan_edit.plan` and `.patch`; narrator branches distinguish recording, exact system speech, and exact Piper speech. `narration` accepts only `mediaRef`.
- Schema descriptions identify recording and model/config identities as app-measured readback, not accepted input. Exact identifiers and explicit delivery are required; Piper pitch is fixed at 1. A local-speech request requires language. Managed synthesized attachment proof remains explicitly unavailable.
- Managed Agent instructions choose/record narrator intent before storyboard approval, attach matching supplied recording afterward, and measure before assembly. Generic `generate_speech` receipts and package metadata cannot satisfy managed narration proof. Unrelated finishing instructions and generic speech prosody text were preserved.
- Localized narrator copy and integrated gate evidence are recorded below.

Schema constraints: `narrationIntent.startFrame` is a required integer from 0 through `maxFrameArg` (1,099,511,627,776). Require `kind` and `mediaRef` for recording; require `kind`, `engine`, `voiceIdentifier`, `rate`, and `pitch` for local speech. Both multipliers use inclusive bounds 0.5–2, with Piper pitch fixed at 1. Narrator branches and source objects reject extra keys. Language and narrator may be omitted for generic intent drafts, but managed approval refuses incomplete intent. Narration source requires only `mediaRef`.

## Slice ownership

Changed source files:

- `Sources/CompositorPro/Agent/Plans/`: `EditPlan.swift`, `PlanNarration.swift`, `StoryboardResolver.swift`, `NarrationTimingService.swift`, `StoryboardPreviewSnapshot.swift`, `StoryboardPreviewService.swift`, `StoryboardView.swift`.
- `Sources/CompositorPro/Editor/ViewModel/`: `EditorViewModel+EditPlans.swift`, `EditorViewModel+PlanNarration.swift`, `EditorViewModel+Storyboard.swift`, `EditorViewModel+StoryboardEditing.swift`, `EditorViewModel+StoryboardPreview.swift`.
- `Sources/CompositorPro/Agent/Tools/`: `ToolExecutor+Plan.swift`, `ToolExecutor+PlanNarration.swift`, plus narration-only hunks in `ToolDefinitions.swift` and `AgentInstructions.swift`. Existing unrelated finishing hunks remain intact.

Changed tests under `Tests/CompositorProTests/Agent/`: `NarrationIntentTests.swift` (new), `PlanNarrationTests.swift`, `PlanNarrationMCPTests.swift`, `StoryboardMCPTests.swift`, `StoryboardEditingTests.swift`, `StoryboardPreviewControllerTests.swift`, `StoryboardPreviewSnapshotTests.swift`, `StoryboardPreviewServiceTests.swift`.

This slice does not edit speech synthesis/generation/import, package/media-library ownership, or shared editor root files. Other dirty files belong to independent work.

## Verification plan

Automated coverage includes isolated MCP approval without an artifact, exact recording attachment, measurement retaining revision/approval, independent timeline readback, persistence, and undo. Unit coverage checks material-intent matrices, derived artifacts, unsupported delivery, unknown voice, raw update refusal, mismatch, no-op, and deterministic cancellation/stale/failure gates. Existing generic narration and preview fixtures use the separated placement field.

Commands executed from the independent verification root, with each gate running inside `package/`:

```bash
python3 run_gate.py normal-build swift build --disable-automatic-resolution --skip-update --jobs 4 --cache-path .build/local-cache --config-path .build/local-config --security-path .build/local-security --manifest-cache local
python3 run_gate.py focused-tests swift test --disable-automatic-resolution --skip-update --jobs 4 --cache-path .build/local-cache --config-path .build/local-config --security-path .build/local-security --manifest-cache local --filter 'NarrationIntentTests|RecordingNarratorValidationTests|PlanNarration|StoryboardMCPTests|StoryboardEditing|StoryboardPreview'
```

Main session runs final integrated narration/storyboard tests, normal and BundledSpeech builds, broader tests, and concurrency diagnostics after shared slices freeze. Isolated evidence below does not establish shared-tree or native UI verification.

### Isolated verification evidence

The independent verification package is `/private/var/folders/3v/qg3xv_lj5wz8_83qnp3zz6yc0000gn/T/opencode/narration-integration-7w72kp4v/package`. Its source is main's immutable `agent-delegation-staged-0g_t_4n_` snapshot plus the exact owned narration files and narrow narration schema/instruction patches. Three unrelated `ToolExecutor+Plan.swift` finishing hunks were excluded. The original snapshot was not modified.

`Package.swift` and `Package.resolved` are unchanged from the verified base. Dependencies and binary dependency artifacts were cloned into this package's independent scratch path; no compiled build output or shared writable dependency symlinks were copied. `snapshot-manifest.json` records the overlay hashes and resolved-file hash. Selected patches are in the sibling `patches/` directory.

- Parser: passed, exit 0, over all 24 owned Swift files. Exact command and file list: `logs/parser.json`; output: `logs/parser.log`.
- Normal build: passed, exit 0. Convex binary dependency emitted macOS 26.2-versus-26.0 linker warnings. Exact command and terminal result: `logs/normal-build.json`; output: `logs/normal-build.log`.
- Focused unit/MCP tests: passed, exit 0; 89 tests in 11 suites. MCP discovery/refusals and approval without audio → matching attachment → measurement → assembly passed, with independent state readback, persistence, and undo assertions. Deterministic cancellation/stale/failure regressions and preview rendering/cancellation also passed. Exact command and terminal result: `logs/focused-tests.json`; output: `logs/focused-tests.log`.
- Warnings remain: the focused log contains 331 warning lines, including deprecated `--skip-update`, compiler diagnostics in the frozen base, and linker diagnostics. Expected negative-path tool refusals also log warnings. Complete diagnostics are retained; the gate is not warning-free.
- Scoped `git diff --check` passed. Frozen hashes and live owned sources/selective patches were checked; unrelated finishing/prosody edits remain intact. Only documentation changed after the passing gates; gate-time hashes are retained in `verified-input-manifest.json`.
- Localization sync, native UI verification, BundledSpeech integration, full tests, and concurrency diagnostics were not run here and remain main's final gates. Isolated tests do not establish integrated speech generation or native UI success.

Manual native verification: select a plan with explicit recording intent and no attachment; inspect narrator identity/language/start; approve inspected visuals; attach matching audio and measure; confirm approval remains current and measured preview plays correct audio. Check different bytes, missing source, changed selection, Escape/dismissal, undo/redo, and material intent edits. A local-speech intent may be approved if complete and available, but production must remain visibly blocked.

### Combined package baseline

Frozen `combined-narration-1` passed 126 tests in 20 suites with unchanged source hashes. It combines the committed package lifecycle with narration/storyboard, persistence, media undo/import MCP, generic speech, and identity regressions. This baseline did not contain the new relink-away-and-back regressions; their proof and subsequent gates follow below. No pinned synthesis, native UI, real audible-quality, complete quit, or installation verification is claimed.

Frozen `narration-source-before` reproduced stale source acceptance in asynchronous attachment validation, prepared attachment commit, and alignment completion: three tests in two suites recorded ten issues, including plan/timing mutations and new undo actions. Existing negative cases still passed; only URL-and-identity restoration exposed these failures. The narrow fix snapshots exact `MediaAsset.PreparationContext` in both validation and timing-session owners. Frozen `narration-source-after` passed all three tests in two suites, covering 20 parameterized cases and prepared narrator selection, with unchanged source hashes. Stale restoration refuses without plan/timing/timeline mutation or undo registration. Native verification remains pending.

Isolated localization sync passed and generated nine English keys. Checker validated 1,421 strings with 9,126 non-English coverage/unknown-key warnings. Non-English catalogs are unchanged; no complete translation-coverage claim is made. Final combined build/test/BundledSpeech/sanitizer gates use this generated inventory.

### Integrated narration gates

Frozen `narration-source-regression-fektq4ey/package` completed all five sequential gates with unchanged source hashes:

- `narration-build`: `swift build` passed.
- `narration-focused`: `swift test --filter 'PlanNarration|NarrationIntent|RecordingNarrator|NarrationTiming|Storyboard|PlanEdit|EditPlanPersistence|ProjectPlanSave|ProjectClosePersistence|ProjectPackageMediaUndo|ProjectPackageImportMCP|GenerateSpeechToolTests|MediaInputIdentity'` passed 127 tests in 20 suites.
- `narration-full`: `swift test` ran 2,484 tests in 363 suites and failed two issues: unchanged custom-model test ordering and a Piper process crash in `SpeechSynthesizerTests.longerTextRendersMoreAudioThanShorterText` (`recursive_mutex lock failed: Invalid argument`, exit 6). Speech implementation/tests remain byte-identical to HEAD; the Piper cause is unresolved. No full-suite pass is claimed.
- `narration-bundled`: `swift build --traits BundledSpeech` passed.
- `narration-tsan`: `swift test --sanitize thread --filter 'PlanNarration|NarrationIntent|RecordingNarrator|NarrationTiming|Storyboard|ProjectPackageMediaUndo|ProjectPlanSave|ProjectClosePersistence|MediaInputIdentity'` passed 109 tests in 17 suites without race diagnostics.

Exact gate records and logs are retained as `package-lifecycle-narration-{build,focused,full,bundled,tsan}.{json,log}` in the approved temporary root. The commit candidate changes only documentation after these gates; source and generated-resource hashes are preserved. These results exclude transport/scoped-close integration and strict approved synthesis. Human native UI/playback, real speech quality, minimum-OS/compiler compatibility, production/recovery/delivery, signing, and installation remain unfinished.
