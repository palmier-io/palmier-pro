# Regression proof and completion

Read for tests, completion checks/claims, commits, or pull requests.

## Test design

- Prefer Swift Testing, `#expect`, and `#require` for new unit coverage unless XCTest/AppKit APIs require otherwise. One concise test proves one behavior/invariant.
- Use descriptive test names, parameterized boundary matrices, and existing small fixtures from `Tests/CompositorProTests/Fixtures.swift` and the affected suite. Do not copy large setup graphs or couple tests to private implementation/call counts.
- Add a regression that fails for the original defect when practical. Check the requested outcome and preserved behavior, not only a success response.
- Cover relevant validation, no-op/repetition, partial failure, cancellation, stale completion, cleanup, and invariant-preservation paths.
- Swift Testing suites run in parallel by default. Use isolated defaults/caches/projects/ports, unique temporary directories, awaited cleanup, and off-main file-I/O fixtures. Keep real user files, network services, and credentials out of unit tests.
- Make concurrency deterministic with gates/continuations/injected hooks, not sleeps or scheduling luck. Performance tests need a stable representative workload and meaningful assertion.

## Select gates by affected behavior

- Swift changes: `swift build`, then `swift test --filter 'SuiteTypeName'`. Match declared suite type names, not directory names or display labels. Confirm nonzero expected test execution; use `swift test list` when uncertain.
- Core editor, persistence, undo, concurrency, shared infrastructure, or broad refactor: also `swift test` before completion. Filtered runs do not replace this gate or avoid compiling the test target.
- Speech/MLX/transcription/bundled models: also `swift build --traits BundledSpeech`; run affected conditional tests with `swift test --traits BundledSpeech --filter 'SuiteTypeName'`.
- AWS-conditional changes: `swift build --traits AWSSupport` and affected conditional tests. If both optional paths interact, verify the combined trait configuration as well.
- Concurrency changes: exercise cancellation and lifecycle paths; use `swift test --sanitize thread --filter 'SuiteTypeName'` or relevant concurrency diagnostics when applicable.
- UI copy: `zsh scripts/localization/sync.sh`. For non-English catalog changes, `node scripts/localization/check.mjs --require-complete`; warnings from a non-strict run do not prove complete coverage.
- Bundled resources/packaging: build, run affected lookup tests, verify `swift run` and final `.app` layout. Use `scripts/bundle.sh debug --fast` only when packaging verification is needed, with applicable traits.
- UI behavior: supply a short manual setup/action/expected-result plan with relevant keyboard, mouse, Escape, focus, undo, disabled/empty, and lifecycle cases. User confirmation is required before recording a UI pass.
- Agent/MCP changes: follow `.agents/skills/compositor-mcp-test/SKILL.md`; exercise discovery/schema when changed, representative requests, invalid/no-op cases, state readback, undo, stable IDs, and async termination. HTTP listener/session changes also need isolated HTTP verification.
- Guidance/tooling only: `python3 -B scripts/agents/check.py`, `python3 -B -m unittest discover -s scripts/agents -p 'test_*.py'`, and `git diff --check`. No Swift gate unless app/build/resource behavior changed.
- Run Swift gates sequentially in one checkout; never race shared `.build` state or accept stale `--skip-build` proof. Rerun affected gates after final edits.

## Evidence and handoff

- Inspect final diff/status for unintended changes, missing call sites, temporary diagnostics, and untested behavior. Do not discard unrelated work or hide failures by changing the test scope.
- Record exact commands/results. A failure is pre-existing only with baseline evidence; otherwise say its relationship is unconfirmed. A narrower pass does not turn a failed full suite into success.
- Report blocked/unrun build, unit, trait, sanitizer, package, UI, or MCP checks precisely and provide concrete manual steps where required. Never claim minimum-toolchain/runtime, end-to-end, performance, or zero-regression proof from a narrower check.
- Stop when the requested outcome and applicable gates are satisfied. Report out-of-scope findings rather than fixing them unsolicited.
- Commit/PR titles use a lowercase bracketed category and imperative summary, e.g. `[fix] Prevent stale export completion`; do not mix unrelated formatting/cleanup.
- PR bodies include Summary (change/impact/why), Approach (owners/invariants/tradeoffs), Testing (exact commands/results and manual/unrun scenarios), and aggregate additions/deletions by code/test category. Large architectural changes also include before/after Mermaid data-flow or lifecycle diagrams.
- Describe the resulting change, not the development chronology. Open substantial PRs as drafts until checks pass and required manual verification is identified or completed.

Reference: [Swift Testing](https://developer.apple.com/documentation/testing).
