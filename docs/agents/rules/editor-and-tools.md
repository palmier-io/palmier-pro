# Editorial mutations and Agent tools

Read for timeline/model edits, selection, linking, undo, or Agent/MCP contracts.

## Shared mutation ownership

- Start at `Sources/CompositorPro/Editor/ViewModel/EditorViewModel.swift` and the owning `EditorViewModel+*.swift` capability. Use existing placement, ripple, overwrite, linking, and timing operations rather than parallel implementations.
- UI, Agent, preview, validation, execution, persistence, and undo must share eligibility, math, clamping, timing, placement, linking, and mutation helpers.
- Resolve the entire request before mutation. Validate empty/nil, duplicate/missing/stale IDs, track locks, unsupported combinations, finite values, bounds, and overflow before arithmetic, indexing, or numeric conversion.
- Assertions protect programmer invariants, not external files, Agent requests, recoverable input, or lifecycle races.
- Keep exact time in frame integers or `CMTime`; define source-versus-timeline time, rounding, speed, trim, and time-scale conversion. Do not silently clamp invalid requests.
- Test linked/split clips, nests and changed child timelines, multicam groups, locked/sync-locked tracks, overlaps, empty/zero-duration timelines, missing media, unusual layouts, and selection/focus changes when affected.
- Batch bulk mutations. Flush pending state before save/undo snapshots, export, close, or reads promising current data. Derived state needs explicit invalidation, not a second mutable source of truth.

## Undo

- Use `Sources/CompositorPro/Editor/EditorUndo.swift` for both UI and Agent edits. One coherent user intent is one action.
- Validate before grouping. Failed, cancelled, refused, unchanged, and repeated no-op operations must not add empty undo steps or misleading success.
- Nested work coalesces into its outer action without closing groups owned by AppKit or another subsystem. Do not absorb adjacent UI or concurrent Agent edits.
- Undo restores exact state and selection without frame drift or orphaned links. Preserve backing bytes needed for redo and references; use the package coordinator for file changes.
- Cover UI/Agent interleaving, automatic AppKit event grouping, concurrent tool requests, and project switching when undo is affected.

## Tool contracts

- Trace `Sources/CompositorPro/Agent/Tools/ToolDefinitions.swift`, the owning `ToolExecutor+*.swift`, the shared editor operation, and `Sources/CompositorPro/Agent/MCP/MCPService.swift`.
- Design one atomic filmmaker action from representative user requests, not internal service boundaries. Define outcomes, eligibility, warnings, failures, cancellation, retries, idempotency, and undo before the schema.
- Do not force low-level orchestration onto the Agent or add an unrelated multi-mode god tool. Keep parameters user-facing and entity IDs stable; labels/indexes are context, not the only identity.
- Treat every argument as untrusted. Require exact types, finite numbers, explicit bounds, valid IDs, and supported combinations. Resolve aliases/duplicate targets before applying multi-entity changes atomically.
- Use the UI's domain operation. Do not silently retarget, reorder, clamp, select alternatives, or fall back unless the contract explicitly promises and reports it.
- Return structured receipts with changes, stable IDs, explicit no-op state, warnings/skips, and actionable errors. Adjusted or unachieved outcomes are not unconditional success.
- Long-running work exposes an inspectable job or terminal result; asynchronous failure must remain observable after the initiating response.
- Keep identifiers, statuses, tool errors, persistence values, analytics, and protocol copy machine-facing and unlocalized. Internal refactors should not change a well-designed public contract unnecessarily.
- Descriptions explain when/why to use a tool, constraints, and interactions rather than repeating parameter names.
- Verify through MCP with isolated data, independent state readback, and shared undo; follow `.agents/skills/compositor-mcp-test/SKILL.md`.

Reference: [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/); use established filmmaking and Apple-platform terminology.
