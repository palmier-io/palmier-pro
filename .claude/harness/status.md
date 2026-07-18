# fix/caption-anim-onset — Status

Phase 2 complete. Ready for Evaluator.

## FIX-A — animation granularity (per-char now opt-in)

| Area     | Change                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------ |
| Model    | TextAnimation.granularity (word default \| char), tolerant Codable — missing key → word          |
| Renderer | TextFrameRenderer.animationUnits(in:granularity:): word groups CJK via NLTokenizer, char = today |
| Timings  | Word units reuse tokenTimings alignment → union of per-char spans; nil timings → even fallback   |
| Tools    | granularity param on update_text/add_texts/add_captions (schema + parse, default word)           |

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
- `swift test` (full) — 1198/1198 pass.
- New: CaptionResyncRetimeTests (7), granularity render/parse tests (11), OnsetRefiner cap (1).

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
