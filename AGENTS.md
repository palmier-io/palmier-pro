# Compositor Pro

Native macOS video editor. Swift tools 6.2; SwiftUI, AppKit, AVFoundation. Target macOS 26 and arm64 only. Non-sandboxed Developer ID app. Do not add backward compatibility, migrations, or obsolete fallback paths.

## Task loop

1. Check `git status --short`. Preserve unrelated work. Do not commit, stage, reset, or expand scope without authorization.
2. Define the requested outcome, acceptance checks, and behavior that must remain unchanged. Reproduce a bug before fixing it when practical.
3. Find the owning operation and its callers before editing. Use [feature navigation](docs/agents/README.md) only for unfamiliar areas. Trace affected UI, Agent/MCP, undo, persistence, and background paths; mark irrelevant paths explicitly rather than inventing work.
4. Read every applicable rule below, including rules for behavior reached through callers. For nontrivial work, identify the source of truth, mutable-state owner, executor, invariants, failure/cancellation behavior, and file placement.
5. Make the smallest coherent change, add focused regression coverage, verify, and stop when acceptance checks pass. Do not mix unrelated cleanup into the task.

## Read rules on demand

These files are mandatory when their trigger applies. Paths in inline code are repository-relative; Markdown links resolve from their containing file. Read only relevant files, not this entire directory.

- Tasks, actors, callbacks, asynchronous state, gates, or filesystem work: [concurrency](docs/agents/rules/concurrency.md).
- Timeline/model edits, selection, undo, or Agent/MCP tools: [editor and tools](docs/agents/rules/editor-and-tools.md).
- Project packages, document save/open/close, media installation/removal, generation publication, or Save As: [project packages](docs/agents/rules/project-packages.md).
- Playback, scrubbing, media/audio processing, rendering, export, indexing, inference, or caches: [media and performance](docs/agents/rules/media-and-performance.md).
- SwiftUI/AppKit, interaction, styling, localized copy, bundled resources, or packaging: [interface and resources](docs/agents/rules/interface-and-resources.md).
- Tests, verification, completion claims, commits, or PRs: [verification](docs/agents/rules/verification.md).
- Code review: [.cursor/BUGBOT.md](.cursor/BUGBOT.md), plus the affected rules above.

## Project skills

Load only the matching workflow. If the harness does not advertise it, read its `SKILL.md` directly. Do not load generic web/React/video-authoring skills for native Swift maintenance.

- [compositor-change](.agents/skills/compositor-change/SKILL.md): implement or fix app behavior.
- [compositor-mcp-test](.agents/skills/compositor-mcp-test/SKILL.md): change or verify Agent/MCP tools or transport.
- [compositor-review](.agents/skills/compositor-review/SKILL.md): review without editing unless requested.
- [compositor-verify](.agents/skills/compositor-verify/SKILL.md): select and run completion gates without expanding scope.

## Non-negotiables

- Keep one authoritative owner for mutable state. Reuse domain operations; UI, previews, validation, tools, commit, persistence, and undo must share rules and calculations.
- Views render state and forward intent. Put orchestration and mutations with the owning feature; use `Utilities` only for infrastructure shared by independent features.
- Keep expensive work and every filesystem operation off the main actor and main thread. `Task {}`, `async`, synchronous `nonisolated`, and `FileIO` helpers do not prove an executor hop.
- Revalidate identity, configuration, lifecycle, and cancellation after `await` before publishing results. Bound concurrency; own tasks and teardown; complete callbacks exactly once.
- Route live `.compositorpro` and legacy `.palmier` package media changes through `ProjectPackageCoordinator`. Stage complete output, coordinate installation, await cleanup, and preserve the last successful state on failure.
- Validate types, finite values, bounds, identifiers, and overflow before arithmetic or mutation. Define frame rounding/clamping explicitly. Failed, cancelled, refused, and unchanged edits must not mutate or create undo entries.
- One user intent produces one shared `EditorUndo` action. Never close an undo group owned by AppKit or another subsystem.
- Surface success, failure, refusal, or cancellation. Do not swallow interaction failures with `try?` or success-shaped receipts. Keep diagnostics actionable; never log secrets or raw prompts. Keep Agent/MCP values machine-facing, separate from localized UI copy.
- Use `AppTheme` for all UI styling and `L10n` for app-owned copy. Keep user content and technical values verbatim. Use `BundledResource` rather than new resource-probing paths.
- Keep comments to one short line explaining a non-obvious invariant or workaround. Prefer clear Swift API names, small coherent types, and feature-owned extensions; remove dead code and temporary diagnostics.
- Measure performance before claiming improvement. Do not move blocking setup into hot paths or add unbounded caches, eager hydration, or broad observation invalidation.

## Verification gates

- Swift source changes: `swift build` and focused `swift test --filter 'SuiteTypeName'`; confirm the expected tests actually ran.
- Core editor, persistence, undo, concurrency, shared infrastructure, or broad refactors: also run `swift test` before completion.
- Speech, MLX, transcription, or bundled speech resources: also run `swift build --traits BundledSpeech`; run relevant trait-enabled tests when behavior is conditional.
- AWS-conditional code: also build with `--traits AWSSupport` and test the affected conditional behavior. Keep builds working with and without optional traits.
- UI copy: run `zsh scripts/localization/sync.sh`. Non-English catalog changes require complete coverage; see the verification rule.
- Agent tools: verify through the MCP boundary and independently read back state or exercise undo. Direct executor tests alone are insufficient.
- UI behavior requires a short manual plan: setup, actions, expected results, and relevant edge/lifecycle cases. Never claim a UI pass before user confirmation.
- Guidance/tooling-only changes: run `python3 -B scripts/agents/check.py`, its unit tests, and `git diff --check`; no Swift build is required unless app/build/resource behavior changed.
- Run Swift build/test commands sequentially in one checkout. Do not reuse stale `--skip-build` results after changing source, resources, or traits.

## Efficient work and clear output

- Prefer scoped native searches and existing fixtures. Expand only when evidence is insufficient; do not scan `.build/`, `.build-check/`, top-level `models/`, `docs/archive/`, or generated resources by default.
- Batch independent reads. Do not delegate unless requested or an applicable instruction explicitly requires it; delegated work must have a bounded scope and compact evidence.
- Use installed/version-matched documentation first; fetch external docs only for a concrete API gap, subject to harness requirements. Never send secrets or private code to external services.
- Give updates only for discoveries, tradeoffs, or blockers. Lead the final response with the outcome, then exact checks/results and remaining risks. No raw log dumps, repetitive narration, invented abbreviations, or unsupported zero-regression claims.
- Commit/PR titles use `[fix] Prevent stale export completion` style: lowercase bracketed category and imperative summary. Follow the verification rule for PR bodies and draft status.
