# fix/caption-segmentation — Status

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
