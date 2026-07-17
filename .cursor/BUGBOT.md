# Palmier Pro review policy

Use the root `AGENTS.md` as the canonical engineering guide. Review for actionable regressions introduced by the PR or made reachable or more severe by it.

## Priorities

Prioritize data loss, project corruption, crashes, hangs, races, security or privacy exposure, incorrect edits, broken undo, stale results, misleading success, and serious performance regressions. Treat optional cleanup and stylistic preferences as non-blocking suggestions or omit them.

## What to check

- Trace changed behavior through callers, shared state, background work, persistence, undo, UI, and Agent surfaces. Do not review the diff in isolation.
- Verify invariants on success, failure, cancellation, no-op, retry, close, quit, sleep, deactivation, and teardown paths.
- Flag filesystem access, media loading, blocking framework calls, decoding, inference, export, indexing, large transforms, waits, or lock contention on the main actor.
- Do not treat `Task {}`, `async`, or synchronous `nonisolated` code as proof that work is off-main. Follow the executor path.
- Check for state captured before an `await` and committed afterward without identity, generation, configuration, lifecycle, or cancellation revalidation.
- Check task ownership, cancellation propagation, bounded concurrency, balanced gates, exactly-once continuations, callback isolation, and teardown racing active work.
- Check whether separate actors still access shared process-global or non-thread-safe framework state.
- Review filesystem mutations for staging, atomic replacement, same-destination serialization, cleanup, error propagation, package-save coordination, Save As, close, and termination.
- Flag duplicated domain rules. Preview, validation, commit, persistence, undo, UI, and Agent paths must share timing, eligibility, clamping, placement, linking, and mutation logic.
- Check large-project behavior for nested scans, repeated filesystem metadata reads, per-item observed mutations, eager hydration, repeated decoder setup, broad SwiftUI invalidation, unbounded caches, and excessive release logging.
- Review caches for complete keys, limits, invalidation, replacement races, lifecycle reset, and stale-value selection.
- Validate empty, zero, negative, maximum, overflow, non-finite, rounding, time-scale, index, duration, malformed, missing, and stale inputs where applicable.
- Check editor behavior with linked clips, nested timelines, multicam groups, locked tracks, missing media, empty timelines, unusual track layouts, selection changes, and focus changes.
- Check UI cancellation and interaction combinations, including modifiers, Escape, dismissal, disabled state, mouse-up after cancellation, backgrounding, and sleep. Preview state must match committed state.
- Verify validation happens before undo grouping. Failed and unchanged operations must not create undo entries, and one user intent must not absorb adjacent edits.
- Review Agent tools from user intent rather than internal API shape. Require stable IDs, atomic invariant-preserving behavior, shared UI domain logic, explicit no-op state, structured receipts, and observable terminal failures.
- Keep localized UI copy separate from stable Agent and MCP contracts, serialized state, identifiers, and machine-readable errors.
- Check AVFoundation changes for async property loading, exact media time, bounded readers or decoders, cancellation, lifecycle invalidation, and preserved transform, color, alpha, timing, and audio metadata.
- Treat swallowed errors, recoverable-input assertions, unchecked casts, `try?` at interaction boundaries, `nonisolated(unsafe)`, and unchecked `Sendable` as findings unless safety is demonstrated.
- Verify tests reproduce the regression or invariant, cover the important negative or interleaving path, remain deterministic and parallel-safe, and match the PR's claimed validation.

## Finding quality

- Report only findings with a concrete triggering scenario and code path.
- State the violated invariant and user impact, not just the suspicious syntax.
- Point to the narrowest relevant changed lines and give a practical fix direction without prescribing an unnecessary redesign.
- Distinguish correctness defects from optional improvements.
- Do not block on unrelated pre-existing issues unless the PR makes them reachable or more severe.
- Do not report speculative races, hangs, or performance concerns without showing the relevant execution or scaling path.
