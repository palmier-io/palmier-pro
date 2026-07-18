# feature/glossary-persistence — Status

Phase 2 complete. Ready for Evaluator. Full `swift build` + full `swift test` green (1266/1266).

| Item | Change                                                                                                                                                 |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| B1a  | promoteCaptionEdit retargets project -> library scope (cross-project reuse)                                                                            |
| B1b  | glossary.json preserved across save-as/duplicate; Project.glossaryFilename const                                                                       |
| B1c  | glossary_promote tool (move up scope, higher-precedence wins collision); pure GlossaryPromotion planner; schema + dispatch                             |
| B1d  | glossary_list notes asserted project-scope terms -> promote                                                                                            |
| B2   | Classifier widens sub-threshold CJK variant to enclosing NLTokenizer word (开视频->拍视频 promotes); CJK-only; common-vocab guard on minimal span kept |
| B3   | Corrector enforces Latin word boundaries on the Latin edges of mixed-script variants (AI技术 no longer corrupts OpenAI技术)                            |
| B4a  | Whitespace-only variants rejected in sanitize (read+write) + corrector skips blank                                                                     |
| B4b  | Deterministic lexicographic-canonical tie-break for shared variants (match list + word-span lookup)                                                    |

Decisions:

- Added `@TaskLocal GlossaryScope.sharedRootOverride` (nil in production) so the library (~~/Documents) and global (~~/.config) roots are injectable for tests. A `TestScoping` trait `.isolatedGlossaryRoot` binds it to a fresh temp dir per test (recursive), applied to the Glossary, Glossary tools, and CaptionLint tool suites so EVERY glossary read and write hits an isolated root, never $HOME. Verified: glossary paths absent after two full runs. Gave the CaptionLint autoApply test a FixedWordSource so the post-promotion resync rebuilds instead of clearing (no transcript in that unit).
- glossary_promote is a MOVE (writes toScope, removes from fromScope); collision resolved by scope precedence (promoted wins when its scope is higher precedence).

Deviations:

- Updated the classifier test `doesNotPromoteUnsafeShortVariant` (我的师父->我的狮父) — with B2 it now widens and promotes (师父->狮父); added a no-context nil case (师->狮) in its place.

---

# feature/caption-lint — Status

Phase 2 complete. Ready for Evaluator.

## caption_lint — transcript-correction lint stage

| Area       | Change                                                                                                                                                                                                                     |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core       | CaptionLinter (pure): flag/context/partition + JSON parse; LintExclusions masks glossary + filler terms                                                                                                                    |
| Completer  | LintCompleter protocol; AgentLintCompleter drains AgentClient.stream (tools:[]); reachable() mirrors selectClient                                                                                                          |
| Tool       | ToolExecutor+CaptionLint builds windows from caption text clips w/ neighbour context; paged (200/call)                                                                                                                     |
| Degrade    | flags → context (never errors) when LLM unreachable (nil completer) or the call throws                                                                                                                                     |
| AutoApply  | opt-in autoApplyThreshold routes ≥threshold via update_text(origin:"user") → glossary promotion synergy                                                                                                                    |
| Exclusions | glossary variants/canonicals + caption-style removeAlways/caseByCase/neverRemove/protectedPhrases; masked on the CHANGED tokens only (diff original→suggestion), so an excluded term in unchanged context never suppresses |
| Registered | ToolName.captionLint + ToolExecutor.run + ToolDefinitions schema (flag-only default, both modes documented)                                                                                                                |

## LLM call path found

- App's only primitive is streaming `AgentClient.stream(system:tools:messages:)` (AgentClientTypes.swift). No one-shot API.
- Model selection is private on the per-editor `AgentService`; MCP ToolExecutor path has no AgentService.
- Auth mirrors AgentService.canStream: personal Anthropic key (AnthropicKeychain) OR signed-in account WITH credits (AccountService.shared.isSignedIn && hasCredits). This project's user is NOT signed in (canGenerate:false) → CaptionLintClient.reachable() returns nil → context mode is the primary path.
- Completer stubbed behind LintCompleter protocol; no network in tests.

## Evaluator fix round 1

- F1 (blocker) — exclusion over-drop fixed: excludesChange(original:suggestion:) diffs the two token sequences (common-prefix/suffix) and suppresses only when a CHANGED token falls inside an excluded term's span. Unchanged surrounding tokens no longer suppress. Regressions: 视频-excluded / 开视频→拍视频 still flagged; adjacent 呃 still flagged; a suggestion that edits the excluded term itself is dropped.
- F2 — response field transcriptionSource → lintSource (schema updated).
- F3 — reachable() now requires isSignedIn && hasCredits (mirrors canStream); a zero-credit signed-in user degrades to context.
- F4 — paging switched from a count+frame cursor to a clipId cursor over the total (startFrame,endFrame,clipId) order: response carries nextClipId; continue via afterClipId. No overlapping-window reprocessing.

## Verification

- `swift build` — clean.
- `swift test` (full) — 1224/1224 pass. CaptionLintTests (18): 9 core (开视频→拍视频 flag, filler+glossary exclusion, 3 F1 changed-token regressions, context windows, partition gating, absent-original drop, registration) + 9 tool (flag-only, autoApply ≥threshold rewrites clip, below-threshold, built-in filler excluded, context no-call, unreachable degrade, failure degrade, paging cursor emits each window once, no-captions note).

---

# fix/caption-anim-onset — Status

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
