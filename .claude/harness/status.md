# fix/lazy-reindex — Status

Phase 2 complete. Ready for Evaluator. Full `swift build` + full `swift test` (1358/1358) green.

## Mechanism (verified)

| Step      | Finding                                                                                                                                       |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Bump      | `LocalSpeechEngine.qwen3.cacheTag` qw6→qw7 changed the disk key; qw6 entries orphaned, `hasCachedOnDisk` false for all                        |
| Eager     | `projectOpened`→`sweep` schedules ALL library assets; `preflight` marks every one `needsTranscript`; `indexOne` transcribes each              |
| Serialize | Background transcripts run on `Qwen3ASREngine` (actor); 293 queue up                                                                          |
| Blocked   | `get_transcript`→`timelineWords`→`transcriptsByURL` awaited `TranscriptCache.transcript` on the SAME actor → queued behind the 293 → MCP hang |
| Counter   | UI "n/m" = `SearchIndexCoordinator.batchCompleted/batchTotal` (MediaTab+IndexStatus)                                                          |

## Fixes

| #          | Change                                                                                                                                                                                                                                                        |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 lazy     | `SearchIndexCoordinator.process` gates spoken transcription via `shouldBackgroundTranscribe` — only for assets an OPEN timeline uses; off-timeline media is visual-indexed only, transcribed lazily on read                                                   |
| 1b stale   | `TranscriptCache.cachedOnDiskAllowingStale` falls back to `LocalSpeechEngine.priorCacheTags` (qw6); `TranscriptSearch` flags `stale` hits; `cachedOnDisk` (resync/glossary) unchanged                                                                         |
| 2 scoped   | Cost lands where reads happen (falls out of 1); glossary_apply/resync/project-open verified not to fan out                                                                                                                                                    |
| 3 priority | `sweep` orders via `prioritized` (active→open→rest); worker calls `BackgroundTranscriptionGate.waitUntilIdle` between items so reads preempt                                                                                                                  |
| 4 nonblock | `get_transcript` returns cached clips now + `pending[]` markers; `graceBoundedLocalTranscripts` (3s constant `uncachedReadGrace`) fires lazy transcription but bounds the wait; scoped reads only await their own clip; response gains `indexing{done,total}` |

## Per-reader stale-vs-regenerate decision

| Reader                                | Behavior                                    | Why                                                                        |
| ------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------- |
| Spoken search (`TranscriptSearch`)    | Stale fallback (qw6), flagged               | Keyword recall; pre-punctuation text is fine, better than blank            |
| `get_transcript` full read            | Regenerate under qw7 (lazy, grace-bounded)  | Needs current word stream; pending marker instead of block                 |
| Resync (`TimelineTranscriptProvider`) | Current tag only, skip uncached (unchanged) | Retiming must match the qw7 text generation produced; stale would mis-time |
| glossary_apply                        | Current tag only, skip uncached (unchanged) | Same correctness concern; not the reported path                            |

## Files

- `Transcription/BackgroundTranscriptionGate.swift` (new) — read/background preemption
- `Transcription/LocalSpeechEngine.swift` — `priorCacheTags`
- `Transcription/TranscriptCache.swift` — `.localTag` variant, `cachedOnDiskAllowingStale`
- `Transcription/TranscriptSearch.swift` — stale fallback + `Hit.stale`
- `Search/SearchIndexCoordinator.swift` — timeline-ref providers, `shouldBackgroundTranscribe`, `prioritized`, worker yield
- `Editor/ViewModel/EditorViewModel.swift` — `mediaRefs(inTimelines:)` + provider wiring
- `Agent/Tools/ToolExecutor+Transcription.swift` — grace-bounded reads, pending/indexing payload, read bracket
- `Agent/Tools/ToolExecutor+Media.swift` — inspect_media read bracket
- `Agent/Tools/ToolExecutor+Search.swift` — surface `stale` in spoken results
- Tests: `Search/LazyReindexTests.swift`, `Transcription/StaleFallbackReadTests.swift`

## Deviations

- inspect_media stays blocking on its ONE target (no "unrelated" assets to defer) but brackets the read gate to preempt background. Non-blocking pending shape is get_transcript-only.
- Cloud and forced-locale reads keep the existing blocking TaskGroup (not the serialized-actor bug; locale bypasses cache by design).

---

# feature/tool-ergonomics — Status (wsD)

Phase 2 complete. Ready for Evaluator. Full `swift build` + full `swift test` (1264/1264) green.

## Items shipped (D1–D6)

| ID  | Change                                                                                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | add_texts `onOverlap` 'clear'(default, now documented)\|'fail'. fail validates every entry vs existing clips on its target track BEFORE mutating; errors with ids   |
| D2  | update_text `entries:[{clipId,content}]` — per-clip content, one undo, shared style/anim/transform; retimer + promotion run per entry; mutual-exclusion + dup guard |
| D3  | update_text desc states auto-promotion; response names first non-promoted reason (classifyWithReason or "no caption group"); undo desc notes glossary not reverted  |
| D4  | AgentInstructions caption-pipeline paragraph (caption_style→add_captions→caption_lint→update_text→resync)                                                           |
| D5  | CaptionBuilder: naturalLines merges punctuation-only lines; time() continues on zero-alnum line instead of break (auditor F3)                                       |
| D6  | add_captions response `resolved` echoes segmentation/maxWords/fillerPolicy/typographyFrom                                                                           |

## Coordination / deviations

- D3b classifier addition is PURE ADDITION to GlossaryClassifier.swift (new RejectReason/Outcome + classifyWithReason at file end); `classify` untouched. Low conflict with builder-wsB.
- D1+D2+D3 share ToolExecutor+Texts.swift, ToolDefinitions.swift, ToolExecutorTests.swift → bundled into one commit (interactive git staging unavailable to split same-function hunks). D3b, D4, D5, D6 are file-disjoint, own commits.
- ToolDefinitions changes are additive (new params/description text only).
- ENV NOTE (not my bug): Glossary/CaptionLint tests non-hermetically read the shared library glossary at `~/Documents/Palmier Pro/glossary.json`. A concurrent builder's promotion test polluted it (provenance auto:caption-edit@<uuid>), failing 9 unrelated tests. No test in THIS worktree writes there (all use temp projectURLs). Cleaning the file → 1264/1264 green. The hermeticity gap lives in wsB/wsC-owned store/tests; left untouched per coordination rules.

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

---

# feature/caption-ui-resync — Status (uiA)

Phase 2 complete (A1–A5). Ready for Evaluator. Full `swift build` + full `swift test` (1379/1379) green.

## Items shipped

| ID  | Change                                                                                                     |
| --- | ---------------------------------------------------------------------------------------------------------- |
| A1  | UI-origin reactive-resync toast. `CaptionResyncReport.uiToast` (pure decision) + `presentReactiveResyncToastIfNeeded()` hooked at end of `TimelineInputController.mouseUp`. |
| A2  | Amber `!` conflict pill (dot fallback) on caption clips with `resyncConflict`, in `ClipRenderer.draw`, gated by `showDetailChrome`. |
| A3  | TextTab conflict warning row + Keep mine / Use transcript. VM helpers `keepManualCaptionText` / `useTranscriptForCaptionConflicts` (overwrite-policy resync scoped to flagged clips). |
| A4  | TextTab "Freeze captions" toggle → `setCaptionResyncExempt` group-wide. Engine already honors `resyncExempt` (group exclusion); locked with a test. |
| A5  | Shared `EditorViewModel.promoteCaptionEditIfClean` (classify + library write + §5.1 mark-clean) used by BOTH `update_text` and the new `promoteInspectorCaptionEdit` (toast + §5.2). MCP behavior byte-identical; `ToolExecutor.promoteCaptionEdit` removed. |

## Design decisions

- **A1 hook**: single site at the end of `mouseUp` — covers every timeline drag/trim/ripple commit. Origin
  is inferred structurally (agents consume via `takeResyncReport`; UI doesn't), so no explicit origin flag.
  A3 "Use transcript" and A5 promotion both consume their own report so A1 never double-toasts.
- **A5 shared shape**: helper returns a `CaptionEditPromotion` carrying both the classifier spans (drive §5.2)
  and the stored spans (drive the response row / toast). Glossary write stays outside undo (unchanged caveat).

## Deviation / for the lead

- The persistent `resyncConflict` flag (drives A2 badge + A3 marker) is only SET by the engine under the
  `.flag` conflict policy; the default reactive policy is `.preserve`, which records conflicts in the REPORT
  (so A1's toast fires) but does not set the flag. So A2/A3 are live only when the conflict policy is `.flag`
  — presumably exposed by the sibling caption-settings cluster (#16). I did NOT change engine policy
  semantics (out of scope, would break agent resync tests). Flag if A2/A3 should also light up under preserve.

## Files

- New: `Editor/ViewModel/EditorViewModel+GlossaryPromotion.swift`, `Editor/ViewModel/EditorViewModel+CaptionConflict.swift`
- Changed: `UI/AppTheme.swift` (Status.captionConflict), `Editor/ViewModel/EditorViewModel+CaptionResync.swift`,
  `Timeline/ClipRenderer.swift`, `Timeline/TimelineInputController.swift`, `Inspector/Tabs/TextTab.swift`,
  `Agent/Tools/ToolExecutor+Texts.swift`, `Agent/Tools/ToolExecutor+Glossary.swift`
- Tests: `Tests/PalmierProTests/CaptionResyncTests.swift` (4 new suites)
