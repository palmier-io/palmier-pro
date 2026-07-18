# Caption Timing Fixes — Status

Phase 2 complete. Ready for Evaluator.

## Delivered

| Bug   | Fix                                                                 | Commit  |
| ----- | ------------------------------------------------------------------- | ------- |
| BUG-4 | `WordTiming.aligned` threaded end-to-end + surfaced in get_timeline | 80528c9 |
| BUG-3 | `OnsetRefiner` acoustic onset rollback; wired Qwen3 + Whisper       | fb2c680 |
| BUG-5 | `WordTimingRetimer` incremental re-alignment; shared Clip helper    | 4199284 |
| BUG-6 | Per-character CJK animation tokenization in the renderer            | 333e144 |

## Verification

- `swift build` — clean.
- `swift test` — 1161/1161 pass.
- New suites: OnsetRefiner (5), WordTimingRetimer (8), render CJK/aligned (3), get_timeline detail (1), update_text retime (2).

## Notes

- Cache tags bumped qw5→qw6, wk1→wk2 so existing transcript caches regenerate.
- Onset engine is fps-agnostic; lead-in bias uses a fixed 30fps reference.
- BUG-3 root cause: first-after-pause word inherits a chunk/anchor-quantized start.
- Worktree needed `Vendor/sherpa-onnx.xcframework` symlinked from the main checkout
  (gitignored binary artifact, not carried into worktrees).
