# feature/transcription-model — Status

Phase 2 complete. Ready for Evaluator.

## Scope

Make the transcription model visible and configurable from the MCP layer. Root cause: a captioning
run silently used local (Qwen3) because the account lacked cloud credits, and the model was invisible
to agents — only `transcriptionSource local|cloud` leaked out, and the local engine choice was an
undocumented app-global UserDefaults key.

## Deliverables

| #   | Area            | Change                                                                                                                                                                                       |
| --- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Docs            | Inline doc at both decision points: engine routing (Transcription.transcribe) + cloud-vs-local (resolveTranscriptionProvider).                                                               |
| 2   | Preference      | TranscriptionPreference auto\|cloud\|local persisted in project.json (ProjectFile, tolerant); set via set_project_settings. cloud fails loudly (actionable ToolError) rather than degrading. |
| 3   | Engine override | SKIPPED — see below.                                                                                                                                                                         |
| 4   | Resolved model  | TranscriptionResult.model stamped at engine/provider boundary; surfaced as transcriptionModel + transcriptionSource in get_transcript, add_captions, inspect_media.                          |
| 5   | Fallback notice | transcriptionNote on get_transcript/add_captions only when preference==auto degraded to local.                                                                                               |

## Selection logic (documented)

- Engine routing (Transcription.transcribe): local engine read from app-global `localSpeechEngine`
  UserDefaults (qwen3 default \| whisper \| apple). qwen3/whisper run first; on failure the code falls
  through to Apple SpeechTranscriber. The model that ran is stamped onto the result (withModel).
- Cloud-vs-local (ToolExecutor.resolveTranscriptionProvider, pure/testable): auto → cloud when the
  signed-in account can afford the uncached request else local (fellBackToLocal set); cloud → cloud or
  throw; local → always local. estimatedCost==0 counts as affordable (cached reads stay on cloud).

## Deliverable 3 — SKIP rationale

Per-project localEngine override was skipped. The engine is resolved from global state at the BOTTOM of
the stack, in two coupled places: (1) Transcription.transcribe reads LocalSpeechEngine.current for
routing, and (2) TranscriptCache salts the cache key with LocalSpeechEngine.current.cacheTag. A
per-project override would have to thread an `engine:` parameter through TranscriptCache.transcript →
Transcription.transcribe/transcribeVideoAudio AND fold that engine's cacheTag into the cache-key
derivation (else two projects with different engines collide). That is a cross-cutting change to the
transcribe/cache contract — exactly the "complicates the singleton assumptions" case the deliverable
said to skip. The engines themselves (Qwen3ASREngine.shared/WhisperKitEngine.shared) are stateless
singletons and are not the blocker; the global read + cache-key coupling is. Clean follow-up: add
`engine: LocalSpeechEngine` to TranscriptCache.transcript and Transcription.transcribe, deriving the
cache tag from the passed engine.

## Verification

- `swift build` — clean.
- `swift test` (full) — 1228/1228 pass.
- New: TranscriptionModelSelectionTests (23 @Test) — preference matrix, cloud+no-credits error, model
  threading per engine, fallback-notice-only-on-auto-fallback, ProjectFile round-trip + legacy decode,
  set_project_settings surface. GetTranscriptParamTests updated for the new resolvedModel field.

## Integration note (sibling feature/caption-lint)

ToolDefinitions/ToolExecutor edits kept additive: set_project_settings gained one property; add_captions
gained response keys; no existing tool entries removed or reordered.

---

# fix/caption-anim-onset — Status

Phase 2 complete. Ready for Evaluator.

## FIX-A — animation granularity (per-char now opt-in) + off by default

| Area     | Change                                                                                                                                                                                       |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Model    | TextAnimation.granularity (word default \| char), tolerant Codable — missing key → word                                                                                                      |
| Renderer | TextFrameRenderer.animationUnits(in:granularity:): word groups CJK via NLTokenizer, char = today                                                                                             |
| Timings  | Word units reuse tokenTimings alignment → union of per-char spans; nil timings → even fallback                                                                                               |
| Tools    | granularity param on update_text/add_texts/add_captions (schema + parse, default word)                                                                                                       |
| Default  | Animation OFF by default everywhere — audit found no path injects a preset (add_captions/UI/profile all gate inactive → nil). Schemas now state opt-in; explicit request → word granularity. |

## FIX-B — onset boundary retiming on resync

| Area       | Change                                                                                       |
| ---------- | -------------------------------------------------------------------------------------------- |
| Engine     | CaptionResyncEngine retimes CLEAN clips to word span (extend/tighten), clamped to track nbrs |
| Provenance | Dirty / nil-generatedText clips: boundaries never touched                                    |
| Report     | Additive `retimed` list (before/after frames) in report + agentPayload                       |
| Apply      | EditorViewModel+CaptionResync sets startFrame/durationFrames from Replacement                |
| Onset cap  | OnsetRefiner.maxRollback 1.5s → 2.5s (real post-pause lag >1.7s); still bounded by prev end  |
| Cost       | No extra transcript lookups — retiming reads only the words REPLACE already queried          |

## Verification (this branch)

- `swift build` — clean.
- `swift test` (full) — 1206/1206 pass.
- New: CaptionResyncRetimeTests (7), granularity render/parse tests (11), OnsetRefiner cap (1), off-by-default lock-in (7), retiming idempotency (1).

---

# fix/caption-segmentation — Status (inherited)

Phase 2 complete. Ready for Evaluator.

## Scope

Two production caption bugs from a 42-min code-switched zh/en vlog (1120 auto captions,
re-broken into shortest natural semantic units).

## BUG-1 — add_texts orphaned from caption group

| Area           | Change                                                                                       |
| -------------- | -------------------------------------------------------------------------------------------- |
| Inheritance    | ToolExecutor+Texts.swift `addTexts` — new clips default-join a track's uniform caption group |
| Explicit param | add_texts `captionGroupId` (validated); "none" opts out; explicit overrides inheritance      |
| Engine default | CaptionResyncEngine.swift — nil generatedText is now dirty (preserve+conflict), not replace  |
| Schema         | ToolDefinitions.swift add_texts entry gains captionGroupId                                   |

## BUG-2 — fixed ~5-CJK-char guillotine

| Area         | Change                                                                                               |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Segmentation | CaptionBuilder.swift natural mode: hard breaks at 。？！，、；… . ? ! , then NLTokenizer word splits |
| CJK safety   | Never splits a CJK/Latin token; punctuation binds left; maxWords = chars (CJK) / words (Latin)       |
| Plumbing     | segmentation param on add_captions + resync_captions → CaptionRequest + resync chunker               |
| Default      | natural everywhere incl reactive auto-resync; fixedChars = legacy                                    |
| Timing       | naturally segmented phrases still slice per-word timings (karaoke preserved)                         |

## Verification

- `swift build` — clean.
- `swift test` (full) — 1158/1158 pass.
- New suites: NaturalSegmentation (7), AddTexts caption grouping (8); existing CaptionBuilder
  tests pinned to `.fixedChars` as the legacy regression pin.

## Integration notes

- Touched ToolExecutor+Texts (add_texts) and CaptionBuilder — edits kept additive/localized to
  minimize merge with sibling fix/caption-timing (update_text + CaptionBuilder timing threading).
- `parseSegmentation` lives in ToolExecutor+Captions.swift, shared by add_captions and resync_captions.
- Worktree Vendor/sherpa-onnx.xcframework symlinked from the main checkout (git-ignored binary).
