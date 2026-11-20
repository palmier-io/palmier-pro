---
name: compositor-verify
description: Selects and runs Compositor Pro completion gates for the affected behavior, including traits, MCP readback, packages, UI plans, and guidance lint. Use for validation-only requests and final proof after edits; do not expand feature scope.
---

# Verify and stop

All repository paths below resolve from the repository root, not this skill directory.

1. Establish acceptance conditions and inspect the final diff/status. Identify app behavior, shared/editor/persistence/concurrency risk, trait/resource/copy changes, and UI/MCP surfaces even when those callers were not edited.
2. Read `docs/agents/rules/verification.md` and only the affected domain rules. Choose the smallest relevant regression gate while iterating and every required broader gate before completion.
3. Match `swift test --filter` to declared suite type names; confirm expected test execution. Do not report a zero-test run as proof or reuse stale binaries after source/resource/trait changes.
4. Run Swift commands sequentially in this checkout. Preserve command/result evidence; rerun relevant gates after the final edit. Do not suppress a failing full suite by reporting only a filtered pass.
5. For Agent/MCP behavior, follow `.agents/skills/compositor-mcp-test/SKILL.md` and independently verify state/undo/output. For package changes, verify persisted bytes and applicable save/Save As/close/quit paths.
6. UI interaction requires a manual setup/actions/expected-results plan and user confirmation. Trait, package layout, sanitizer, minimum-runtime, or performance proof remains unverified unless that exact check ran.
7. For guidance/tooling-only changes, execute `python3 -B scripts/agents/check.py`, `python3 -B -m unittest discover -s scripts/agents -p 'test_*.py'`, and `git diff --check`; no Swift build unless app/build/resource behavior changed.
8. Fix only task-related failures when authorized. State blockers and baseline evidence precisely; otherwise report the failure's relationship as unconfirmed.
9. Stop after acceptance and required checks. Final output: outcome; exact checks/results; manual verification or remaining blocker. Never promise zero regressions.
