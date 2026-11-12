---
name: compositor-review
description: Reviews Compositor Pro changes for actionable data, editing, concurrency, lifecycle, and verification regressions. Use for code reviews, PR reviews, or final diff audits; do not edit or launch mutating app tools unless requested.
---

# Compositor Pro regression review

All repository paths below resolve from the repository root, not this skill directory.

1. Read `.cursor/BUGBOT.md`; it is the canonical review policy. Establish the requested diff/base and preserve unrelated work. Review is read-only unless fixes were requested.
2. Map changed behavior to its owners and callers. Load only the applicable rules from `AGENTS.md`; use `docs/agents/README.md` for unfamiliar features.
3. Trace success, failure, no-op/repeat, cancellation/stale completion, and teardown through the affected UI, domain mutation, Agent/MCP, undo, worker, and persistence paths. Do not stop at the diff.
4. Prioritize data loss/corruption, crashes/hangs/races, privacy/security, incorrect edits, broken undo, stale results, misleading success, and measured or demonstrable serious performance regressions.
5. Verify executor hops, post-`await` revalidation, task/gate/continuation ownership, package staging/save/close, exact frame math, shared UI/tool rules, bounded work, and cache invalidation where affected.
6. Check regression tests and actual verification evidence. Suspicious syntax, missing tests alone, or an unmeasured speed claim is not proof of a concrete runtime defect.
7. Report only actionable introduced or newly reachable defects with a triggering scenario, narrow changed location, violated invariant/user impact, and practical fix direction. Omit unrelated pre-existing issues and stylistic preferences.

## Output

- Finding: `[P1] path/to/file.swift:line — trigger; incorrect behavior and impact; fix direction.` Use severity matching the evidence.
- If no findings: `No actionable regressions found in the reviewed scope.` Then name material coverage limits or unrun checks.
- Keep output concise without dropping conditions, negations, stable IDs, or uncertainty. Do not claim absence of all bugs.
