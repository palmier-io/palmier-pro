# Compositor Pro review policy

Read `AGENTS.md` and its applicable behavior-scoped rules. This file owns review policy; do not duplicate the engineering checklists here. Review only actionable regressions introduced or made reachable/more severe by the change.

## Priorities

Prioritize data loss/corruption, crashes/hangs/races, security/privacy exposure, incorrect edits, broken undo, stale results, misleading success, and serious demonstrable performance regressions. Omit stylistic preferences and optional cleanup unless requested.

## What to check

- Trace callers, shared state, UI, Agent/MCP, undo, background work, and persistence; do not review the diff in isolation.
- Apply affected rules for executor safety, package transactions, frame math, editorial/tool contracts, media/cache scaling, native interaction, localization, and regression proof.
- Check relevant success, failure, no-op/repeat, cancellation/stale completion, retry, and close/quit/sleep/deactivation/teardown paths.
- Follow actual executor and ownership paths. `Task {}`, `async`, and synchronous `nonisolated` do not prove work is off-main; separate actors do not isolate shared process-global resources.
- Treat swallowed errors, assertions on recoverable input, unchecked casts, `try?`, `nonisolated(unsafe)`, and unchecked `Sendable` as review targets, not automatic findings. Demonstrate the violated invariant and triggering path.
- Verify tests protect the changed behavior and negative/interleaving case, are deterministic/isolated, and match the claimed commands and results. Direct executor tests do not prove MCP behavior; builds do not prove UI behavior.

## Finding quality

- Require a concrete scenario, narrow changed location, violated invariant/user impact, and practical fix direction without an unnecessary redesign.
- Do not report speculative races, hangs, or performance concerns without the execution/scaling path. Missing coverage alone is not proof of a runtime defect.
- Distinguish defects from optional improvements and unrelated pre-existing issues. State coverage limits; no findings does not mean zero bugs.
- Keep findings concise and evidence-based: `[P1] path:line — trigger; incorrect outcome/impact; fix direction.`
