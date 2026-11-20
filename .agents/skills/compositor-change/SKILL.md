---
name: compositor-change
description: Implements Compositor Pro Swift fixes, features, and refactors using feature-owned operations, risk-scoped rules, and regression gates. Use for native app behavior changes, not documentation-only edits or standalone video creation.
---

# Compositor Pro change workflow

All repository paths below resolve from the repository root, not this skill directory.

## Bound the task

1. Read `AGENTS.md` if not already loaded. Check `git status --short`; preserve unrelated changes.
2. State the requested outcome, smallest acceptance scenario, one important preserved behavior, and relevant failure/cancellation case. Ask only when ambiguity affects correctness, scope, or destructive work.
3. For a bug, reproduce it or add a failing focused test before editing when practical. For a refactor, establish baseline behavior before moving ownership.

## Locate and design

4. Use `docs/agents/README.md` only for unfamiliar ownership. Start with the named file/symbol; search its feature and tests before expanding. Do not repeatedly inventory the whole repository.
5. Trace the shared domain operation from UI and Agent/MCP callers through undo, background work, and persistence as applicable. Identify the authoritative owner and existing helper rather than adding a parallel implementation.
6. Load all affected rules from `docs/agents/rules/`, selected by the triggers in `AGENTS.md`. For nontrivial changes, decide executor, immutable input, revalidation, failure/cancellation, consistency boundaries, and file placement before implementation.
7. Reuse the owning `EditorViewModel+*.swift` capability and existing fixtures. Read the nearest relevant contract in `docs/contracts/`; historical audit/pass claims do not establish the current state.

## Implement and prove

8. Make one coherent change at the responsible layer. Validate before arithmetic, mutation, and undo; preserve no-op, repeat, lifecycle, and stale-result behavior.
9. Add concise behavioral coverage at the smallest stable seam, plus the important negative/interleaving path. Tool changes also require `.agents/skills/compositor-mcp-test/SKILL.md`.
10. Follow `docs/agents/rules/verification.md`: focused gates while iterating, broader affected gates before completion. Inspect the final diff and rerun relevant checks after the final edit.
11. Stop when acceptance checks pass. Report outcome, exact verification, and any manual checks/blockers; do not add speculative abstractions or unrelated cleanup.

## Example

For stale caption publication, start in the owning captions extension, load concurrency/package/editor rules, and coordinate a source change at a deterministic gate. Verify no stale commit, no empty undo action, and the ordinary successful path. Do not replace the caption subsystem or test by racing sleeps.
