# Compositor Pro — Open Work

Status of the explainer-production roadmap, reconciled against the actual code on
`main` (not against the prose in `done.md`). Each item says what the code really
does, so the next session starts from evidence rather than a checkbox.

Legend: **Implemented** = code exists and builds; **Partial** = some of the
acceptance exists; **Missing** = no real implementation found; **Unverified** =
code may exist but the human/real-provider proof has not been recorded.

---

## App review — 12 November 2026

Track the complete review findings here. P1 fixes are first; P2 work remains queued unless required by the same fix. Automated proof and manual checks are recorded per item.

- [ ] **R1 / P1 — Safe quit after slow preparation or save.** `App/AppDelegate.swift`: the 15-second watchdog approves termination before final saves necessarily finish. Remove automatic force termination; keep close admission and exactly-once replies through successful saves/drain or explicit failure. Verify delayed preparation, multiple projects, failed save, and retry. Native quit/restart confirmation remains a manual gate.
- [ ] **R2 / P1 — Refuse stale Agent word cuts.** `Agent/Tools/ToolExecutor+Words.swift`, `ToolExecutor+Transcription.swift`: cached track indices and word ranges survive awaits and can cut a different timeline/clip. Revalidate timeline, source identity, clip timing, and track mapping before mutation. Prove through MCP with deterministic source/timeline/track changes, unchanged state/undo on refusal, and normal cut/undo/readback.
- [ ] **R3 / P1 — Preserve independent LUT grades and undo bytes.** `Compositing/LUTLoader.swift`, `Kernels/LUTTetraKernel.swift`: different files with the same basename overwrite a shared stored path and rendering cache identity. Install immutable content-identified LUTs atomically; preserve earlier bytes and use matching renderer identity. Verify same-name imports, repeat/no-op, failure/cancellation, rendered output, persistence, and undo/redo through shared UI/tool operations.
- [ ] **R4 / P2 — Background Agent tabs must finish in their own sessions.** `Agent/Chat/AgentService.swift: isCurrentRun`: selected-chat identity drops background snapshots and cancels pending tool batches. Separate per-session task ownership from selected-tab presentation; test `selectSession` while streaming and running tools.
- [ ] **R5 / P2 — Independent waveform and filmstrip generations.** `Timeline/MediaVisualCache.swift`: starting filmstrips invalidates the same video's waveform generation and leaves its in-flight marker stuck. Separate asset invalidation from per-kind jobs and complete bookkeeping independently. The isolated review probe reproduced this conflict.
- [ ] **R6 / P2 — Persist Agent editing progress at the current document URL.** `Editor/ViewModel/EditorViewModel.swift`, `Agent/Chat/AgentService.swift`: the normal service retains nil as its immutable URL, so progress saves return without writing. Bind coordinated progress snapshots to open/save/Save As/close; verify reopened handoff/progress.
- [ ] **R7 / P2 — Invalidate silence detection when media changes.** `Agent/Tools/ToolExecutor+Silence.swift`, `Audio/Analysis/SilenceStore.swift`: cache keys omit source identity; relink/reset retain old results and late detection can republish them. Add identity-aware invalidation and post-await checks. Both relink invalidation and reset failed the isolated review probe.
- [ ] **R8 / P2 — Stop visible filmstrip eviction/reload churn.** `Timeline/MediaVisualCache.swift`: 25 consumed assets exceed the 24-asset limit; publication evicts a visible asset and redraw restarts decoding. Reconcile cache admission with viewport demand and a byte budget. The production cache probe reproduced 50 consecutive reload cycles; profile idle UI activity before claiming a performance improvement.
- [ ] **R9 / P2 — Bound retained LUT memory.** `Compositing/LUTLoader.swift`: static path-keyed data has no eviction or lifecycle release. A supported 128-point cube retains 32 MiB of RGBA data per entry. Add a byte budget and close/lifecycle release; measure representative retained memory.
- [ ] **R10 / P2 — Move LUT import work off the main actor.** `Agent/Tools/ToolExecutor+Color.swift`, `Inspector/Tabs/AdjustTab.swift`: synchronous read/parse/copy blocks editing and quit coordination. Prepare/install on a bounded worker, revalidate targets, and surface errors before one undo action. This may be required by R3's shared immutable installation.
- [ ] **R11 / P2 — Make folder relinking cancellable and off-main.** `Editor/ViewModel/EditorViewModel+Relink.swift`: recursive enumeration and per-file stats run synchronously on the main actor. Scan on an owned filesystem worker, revalidate assets, and stop once requested matches are resolved where possible. Verify large/network fixtures and UI responsiveness.

Review baseline: `swift test` passed 2,963 tests in 435 suites; two focused runs passed 16 and 52 tests. Four isolated mechanism probes reproduced R3, R5, R7, and R8. These passes do not cover every finding; no Instruments, optional-trait, sanitizer, or native UI pass was claimed for the review.

---

## Reconciled status of the old roadmap

### P0 — Trustworthy inputs and planning

| # | Capability | Real state | Evidence |
|---|---|---|---|
| 1 | Tool discovery/execution contracts | Implemented | 107 tools in `ToolDefinitions.swift`; MCP readback tests pass |
| 2 | Reference → editorial recipe | Partial | `referenceRecipe` on `EditPlan`; no automatic reference analysis |
| 3 | Source & claim ledger | Partial | `sourceLedger` persists claims/passages; consumers (charts, graphics) not all bound — `done.md` says unchecked |
| 4 | Measured narration timing | Partial | `measure_narration` + `NarrationTimingService`; auto paragraph regen/resume missing |
| 5 | Grouped approvals | Partial | blockers grouped in `read_storyboard`; no human UI run recorded |
| 5a | Storyboard review before production | Partial | `prepare_storyboard`/`approve_storyboard`, native panel, animatic render; **no semantic graphic drafts, no MCP animatic endpoint** |
| 5b | No-repeat visual rule | Partial | identity + occurrence audit + export gate exist; **perceptual similarity is `not_checked`, `deliveryVerified` always false** — no perceptual/face detection |
| 6 | Map scenes | Partial | `build_map_scene` with 12-place catalog + Lottie camera; **no region polygons, no plan/ledger binding** |
| 7 | Evidence graphics | Partial | `build_graphic_scene` typed family + narration validator; spec persisted only as receipt, not a first-class plan artifact |
| 8 | Production lifecycle | Partial | `ProductionCoordinator` phases/resume/receipts; **whole-intent native/UI drain missing — quit quiescence blocked** (`docs/contracts/project-close-confirmation.md`) |

### P1

| # | Capability | Real state | Evidence |
|---|---|---|---|
| 9 | Acquire verified coverage | Partial | `find_shot_candidates` + import; no end-to-end coverage workflow proof |
| 9a | Source diversity | Partial | pagination + canonical exclusions + delivery history; **no 24h request cache, no complementary-source eval, no live benchmark** |
| 10 | Preserve editable graphic artifacts | Partial | `EvidenceGraphicSpec` + `digest` now persist on `EditPlan.graphicScenes` with a renderer version; label fixes regenerate via the same spec (MCP readback pending) |
| 11 | Dependency-aware section revision | Implemented | `plan_edit action=revise_section` updates the section, its linked beats, invalidates timing, and reports dependents; unit-tested, MCP readback pending |
| 12 | Review facts/motion/audio/coverage | Partial | `review_timeline` now reports bounded motion (mean/min/max luma delta, frozen spans) + loudness/peak/clip; **still no claim-vs-display check, `perceptualSimilarity: not_checked`** |
| 13 | Intent-level Agent ops | Partial | `produce_plan`, `edit_pilot`, `plan_edit`, `production_status` exist; not all verified end-to-end |
| 13a | Subagents | Partial | `delegate_work` app-only, 2 children; **no real-provider/UI latency proof** (`docs/delegation-verification.md` unrun) |
| 14 | Long-form efficiency | Unverified | benchmark tests exist for lookup/layout/markers, but **no 18–21 min end-to-end measurement** |
| 15 | Caption styles | Partial | `CaptionStyle` + 31 presets + gallery; **native UI verification unperformed** |
| 16 | Export speed | Partial | `ExportSignposts` now emits prepare/export phase signposts + wall-clock to `Log.export`; still no measured before/after comparison |

### Release gates

| Gate | Real state |
|---|---|
| A — 90s landscape proof | Unverified — needs human playback |
| B — 3–5 min chaptered | Unverified |
| C — 18–21 min documentary | Unverified; needs measured prompt count + overlap benchmark |

### Cross-cutting

| Area | Real state |
|---|---|
| Whole-intent admission (quit) | **Blocked** — native edits/UI tasks/HTTP output not drained; see `docs/contracts/project-close-confirmation.md` |
| Signed release | Blocked — Developer ID identity/profile missing (`scripts/preflight-signing.sh` fails) |
| Localization | English source only; ~9.8k non-English coverage warnings |
| Intermittent test | `CustomAgentModelPersistenceTests.aRemoteCustomModelWithAStoredKeyIsSelectable` — wait-order flake, not fixed |

---

## Concrete open work, ordered by impact

### 1. Close the quit/whole-intent hole (blocks release)
- One editor-intent admission lifetime shared by native input, UI tasks, and Agent tools.
- Cancel/drain admitted intents and HTTP output before the final save; keep nested tool/package admission deadlock-free.
- Files: `AppDelegate.swift`, `ProjectPackageCoordinator.swift`, `EditorViewModel+Captions.swift`, `CaptionTab.swift`.

### 2. Finish task 11 (dependency-aware section revision) — highest user value
- Add a `revise_section` plan op resolving one change across speech, maps, captions, music, placement.
- Reuse shared domain ops; one undo action; revalidate uniqueness/approval.
- Files: `ToolExecutor+Plan.swift`, `EditPlan.swift`, `NarrationTimingService.swift`.

### 3. Finish task 5b perceptual + face gate
- Add a bounded perceptual fingerprint pass at preparation; treat similarity as a review signal.
- Make `deliveryVerified` mean something (freshness rehash + similarity + face inspection), or rename it honestly.
- Files: `Media/VisualUniqueness.swift`, `ToolExecutor+ReviewTimeline.swift`.

### 4. Task 16 — measured before/after (instrumentation landed)
- `ExportSignposts` emits phase signposts + wall clock; run a fixed 90s fixture and record before/after.
- Files: `Export/ExportService.swift`, `Export/ExportSignposts.swift`.

### 5. Task 12 — claim-vs-display check
- Motion metrics landed; still missing claim/display agreement and persisted inspection intervals.
- Files: `RenderedTimelineReview.swift`, `ToolExecutor+ReviewTimeline.swift`.

### 6. Task 6 — map regions + plan binding
- Region polygons, plan/ledger binding, plan-side spec persistence.
- Files: `Agent/Maps/MapScene.swift`, `ToolExecutor+MapScene.swift`.

### 7. Task 9a — provider cache + diversity proof
- 24h request cache per provider terms; complementary-source evaluation; live-quality benchmark.
- Files: `MediaSources/*`.

### 8. Human verification pass
- Work through `docs/human-confirmation.md` (19 items) and record Pass/Fail + build/model.
- Then run Gates A/B/C with recorded evidence.

### 9. Release
- Restore Developer ID identity + provisioning profile; `scripts/preflight-signing.sh`; codesign; install; verify legacy `.palmier` package opens.

---

## Plugin-first agent architecture (OpenCut port)

OpenCut's rewrite is plugin-first: third-party plugins ship executable agent tools, not just instructions, plus headless mode and an in-editor scripting tab. Compositor Pro already has Skills (instruction-only agent context) and a baked-in MCP server (~60 tools in a compile-time `ToolName` enum). The gap: third parties cannot ship a new executable agent tool without rebuilding the app. These items close that gap.

### Plugin item 1 — Agent tool plugin registry (core)
Add a `ToolRegistry` that merges third-party tool definitions with the built-in `ToolName` enum. Plugins declare name + JSON input schema + executable entry point; the registry validates, indexes, and dispatches them. Read-only/query tools first (no project mutation) to limit risk.

Files:
- New: `Sources/CompositorPro/Agent/Plugins/ToolRegistry.swift` — registry, `PluginTool` definition, registration/dispatch
- New: `Sources/CompositorPro/Agent/Plugins/PluginManifest.swift` — Codable manifest (name, version, schema, entryPoint, permissions, signature)
- Modify: `Sources/CompositorPro/Agent/MCP/MCPService.swift` — merge registry tools into `registerTools`; keep `listChanged: true`
- Modify: `Sources/CompositorPro/Agent/Tools/ToolExecutor.swift` — add `executePluginTool(name:args:)` path

Steps:
1. Define `PluginTool` (id, name, description, inputSchema JSON, entryPoint, permissionScope) Codable + Sendable.
2. Implement `ToolRegistry` (MainActor) with `register(_:)`, `tool(named:)`, `allTools()`, and `execute(named:args:)`.
3. Wire MCP `ListTools`/`CallTool` to include registry tools alongside built-ins; emit `ToolListChangedNotification` on registry change.
4. Add `ToolExecutor.executePluginTool` that looks up the plugin by name, validates args against its schema, then runs it out of process (item 2).

Acceptance:
- `swift test --filter ToolRegistryTests` passes (register, lookup, duplicate rejection, schema validation).
- MCP client connecting sees built-in + registered plugin tools; calling a plugin tool returns a shaped result.

### Plugin item 2 — Sandboxed out-of-process plugin execution
Run plugin tools in a separate process (XPC or `Process`) with strict entitlements; never load third-party code into the main app process. Compositor Pro is non-sandboxed Developer ID, so code-sign + notarization constraints apply.

Files:
- New: `Sources/CompositorPro/Agent/Plugins/PluginSandbox.swift` — out-of-process spawn, pipe stdio, timeout, exit-code mapping
- New: `Tests/CompositorProTests/Agent/Plugins/PluginSandboxTests.swift`

Steps:
1. Design plugin executable contract: reads JSON args from stdin, writes JSON result (or error) to stdout, exits 0 on success / non-zero on failure.
2. Implement `PluginSandbox.run(entryPoint:args:timeout:)` using `Process` with `/usr/bin/env osascript`-free Swift executable path; capture stdout/stderr; enforce timeout; map exit codes to `ToolResult`.
3. Validate entryPoint path is under a trusted plugin root (not arbitrary filesystem); reject absolute paths outside `~/Library/Application Support/Compositor Pro/Plugins/`.
4. Sandbox restrictions: no network, no project-file write outside the plugin's own container, no keychain access. Enforce via `Process` sandbox profile or entitlement check at launch.

Acceptance:
- A sample read-only plugin (e.g., `list_sample_plugins`) runs out of process and returns JSON via MCP.
- Timeout kills a hung plugin; non-zero exit maps to an error `ToolResult`, not a crash.

### Plugin item 3 — Plugin manifest store + trust model (reuse Skill patterns)
Reuse `SkillStore`/`SkillCatalog` patterns (content hash, ledger, install/sync/delete) for plugin manifests. Trust model: signed plugins run; unsigned plugins require explicit user confirmation and run with reduced scope.

Files:
- New: `Sources/CompositorPro/Agent/Plugins/PluginStore.swift` — install/sync/delete ledger mirroring `SkillStore`
- New: `Sources/CompositorPro/Agent/Plugins/PluginTrust.swift` — signature verification, `PluginTrustLevel` (trusted/untrusted/blocked)
- Modify: `Sources/CompositorPro/Agent/Plugins/ToolRegistry.swift` — consult trust level before dispatch; refuse blocked, confirm untrusted

Steps:
1. Define `PluginTrustLevel` and signature check (Developer ID / ad-hoc / none). Store per-plugin trust decision in a ledger (like `.installed.json`).
2. `PluginStore.install(_:)` validates manifest hash, writes plugin bundle to `~/Library/Application Support/Compositor Pro/Plugins/<id>/`, records trust level.
3. UI surface: plugin management panel (install, trust, delete); untrusted plugins show a confirmation dialog before first run.
4. Plugin tools originating from untrusted manifests are excluded from mutating actions (export, delete, produce) regardless of declared permissions.

Acceptance:
- Installing a plugin writes manifest + bundle, computes sha, records in ledger.
- `swift test --filter PluginStoreTests` passes (install, hash mismatch rejection, ledger persist).
- Untrusted plugin tool call surfaces a confirmation UI; confirmed-once is remembered.

### Plugin item 4 — Headless / scripting CLI for plugins
OpenCut has headless mode + a scripting tab in the editor. Compositor Pro's CLI exists but is currently broken (`CLIHandler.swift` compile failure: `HyperframesCatalogWrapper.inspectBlock(id:)` signature mismatch). Fix CLI first so plugins can run headlessly.

Files:
- Fix: `Sources/CompositorPro/CLI/CLIHandler.swift` — resolve `inspectBlock` signature mismatch
- New: `Sources/CompositorPro/CLI/PluginCommand.swift` — `compositor plugin run <id> --args <json>` headless entry
- Modify: `Package.swift` — ensure CLI target builds cleanly

Steps:
1. Fix `CLIHandler.swift` compile error so `swift build` succeeds (pre-existing blocker, unrelated to plugins).
2. Add `plugin run` subcommand: load manifest from `PluginStore`, validate trust, run `PluginSandbox`, print JSON result to stdout.
3. Add `plugin list` and `plugin trust <id> <level>` subcommands for headless plugin management.

Acceptance:
- `swift build` succeeds (unblocks all CLI/plugin work).
- `compositor plugin list` prints installed plugins; `compositor plugin run <id> --args '{}'` returns JSON.

### Plugin item 5 — Prototype: one read-only sample plugin
Ship one sample read-only plugin end-to-end to prove the loop (manifest → store → registry → MCP → sandbox → result) before opening to third parties.

Files:
- New: `Sources/CompositorPro/Agent/Plugins/SamplePlugins/ReadOnlyInfo.swift` — sample plugin (e.g., reports installed plugin inventory / media counts without mutating)
- New: `Tests/CompositorProTests/Agent/Plugins/PluginE2ETests.swift` — install sample, call via MCP, assert result

Steps:
1. Implement sample plugin as a Swift executable manifest with input schema `{}` and read-only scope.
2. Register it in `ToolRegistry` at startup (built-in sample, not third-party).
3. Call it through MCP `tools/call` and read back the result.
4. Record the full flow as a test so regressions are caught.

Acceptance:
- `swift test --filter PluginE2ETests` passes end-to-end.
- MCP client can discover and invoke the sample plugin tool.

## OpenCut port — additional items

OpenCut's mature design (described in `changelog/0.1.0`–`0.3.0.md`) offers several timeline, theme, audio, canvas, and UX patterns worth porting to Compositor Pro. OpenCut is MIT licensed; reimplement ideas in Swift, do not vendor TS/Rust source. Referenced `rust/crates/` and `src/lib/ripple/` code is **not in this checkout** — treat as design reference only.

Each item below states: **What** (outcome), **Why** (OpenCut reference + value), **How** (steps with preconditions, invariants, failure handling), **Files**, **Preconditions**, **Invariants**, **Failure handling**, **Behavior that must remain unchanged**, and **Acceptance**. An agent should be able to pick any item and implement it without asking clarifying questions.

### Additional item 1 — OKLCH semantic theme system

**What:** Add an optional OKLCH-based semantic theme layer over `AppTheme`, keyed by system appearance (light/dark/vibrant light/vibrant dark), with views opting in via `theme.color(for:)` / `theme.font(for:)`.

**Why:** OpenCut's desktop theme (`apps/desktop/src/theme.rs`) uses OKLCH semantic colors (`background`, `card`, `primary`, `accent`, `destructive`, `border`, `chart_1..5`, `sidebar_*`), radius, and `OnceLock`-cached themes keyed by appearance. Gives Compositor Pro a structured light/dark theme system without hardcoding into `AppTheme`.

**How:**
1. Implement OKLCH → linear sRGB → sRGB conversion in `OKLCHConverter.swift`, matching OpenCut's `oklch_with_alpha` (neutral endpoints: black = 0/0/0, white = 1/1/1; translucent tokens keep alpha).
   - Precondition: input lightness/chroma/hue are finite; hue in degrees [0,360).
   - Invariant: round-trip OKLCH→sRGB→OKLCH preserves neutral endpoints exactly; clamped channels stay in [0,1].
   - Failure: non-finite input → return `.black` (do not crash).
2. Define `SemanticColors` + `Theme` structs (Sendable) with all semantic color fields + `radius`, in `OKLCHTheme.swift`.
   - Invariant: `Theme` is immutable after init; cached instances are shared read-only.
3. Cache light/dark/vibrant-light/vibrant-dark themes in static storage keyed by `NSAppearance` (OnceLock-style).
   - Precondition: called from main actor when resolving for a window.
   - Invariant: same appearance always returns the same cached `Theme` instance (pointer equality).
4. Add `AppTheme.oklchTheme(for appearance:)` accessor returning resolved `NSColor`/`SwiftUI.Color` values, falling back to existing `AppTheme` values when no OKLCH theme is active.
   - Failure: appearance not recognized → fall back to `AppTheme` defaults (never return nil color).
5. Views opt in by reading `oklchTheme.color(for:)` / `.font(for:)`; never hardcode colors into `AppTheme.swift`.

**Files:**
- New: `Sources/CompositorPro/Style/OKLCHTheme.swift`
- New: `Sources/CompositorPro/Style/OKLCHConverter.swift`
- Modify: `Sources/CompositorPro/Style/AppTheme.swift` — add `oklchTheme(for:)` accessor only
- New: `Tests/CompositorProTests/Style/OKLCHThemeTests.swift`

**Preconditions:** `AppTheme.swift` exists and is the single default styling source. No existing view reads OKLCH yet.

**Invariants:** `AppTheme` remains the single default when no OKLCH theme active. OKLCH theme is additive, not replacing.

**Failure handling:** Converter returns `.black` on bad input; unknown appearance falls back to `AppTheme`; never crash on theme resolution.

**Behavior that must remain unchanged:** Existing `AppTheme` colors/fonts used by current views are untouched. No view is forced to adopt OKLCH.

**Acceptance:**
- `swift test --filter OKLCHThemeTests` passes (appearance selection incl. vibrant variants, neutral endpoints round-trip, translucent token alpha preserved, fallback to AppTheme).
- `swift build` succeeds with no new warnings.
- Pointer equality holds for repeated resolution of the same appearance.

### Additional item 2 — Integer tick time + rational frame rate (MediaTime)

**What:** Add `MediaTime` (Int64 tick count at 120,000 ticks/sec) and `FrameRate` (rational `{numerator, denominator}`) for exact timeline time arithmetic, frame snapping, and timecode formatting.

**Why:** OpenCut represents time as `MediaTime` at 120,000 ticks/sec with rational `FrameRate`. 120,000 divides evenly by every standard frame rate incl. drop-frame (23.976→5,005 ticks/frame, 29.97→4,004, 30→4,000). Avoids float drift in timeline scrubbing, playhead, and timecode.

**How:**
1. Define `MediaTime` as a wrapped `Int64` tick count at 120,000 ticks/sec; all arithmetic in integer domain (`MediaTime.swift`).
   - Invariant: ticks are always finite Int64; no floating point used internally.
   - Failure: overflow on add/subtract → return nil (do not wrap silently).
2. Define `FrameRate {numerator, denominator}`; derive `ticksPerFrame` as rational with exact drop-frame mappings.
   - Precondition: denominator > 0; normalize fraction.
   - Invariant: 23.976→5005, 29.97→4004, 30→4000, 24→5000, 25→4800, 60→2000 ticks/frame.
3. Implement frame snapping (nearest/floor/ceil), duration→ticks, ticks→timecode (HH:MM:SS:FF).
   - Invariant: snap(unsnap(t)) == t for integer-aligned values; timecode formats frame number as zero-padded 2 digits.
4. Keep existing `CMTime`-based paths working alongside; migrate timeline scrubbing/playhead to `MediaTime` incrementally (not all at once).
   - Behavior unchanged: existing `CMTime` playback paths continue to work.

**Files:**
- New: `Sources/CompositorPro/Timeline/MediaTime.swift`
- New: `Tests/CompositorProTests/Timeline/MediaTimeTests.swift`

**Preconditions:** Timeline code currently uses `CMTime`/`Float` seconds; both coexist during migration.

**Invariants:** Ticks-per-frame for standard rates are exact constants, not computed floats. `MediaTime` arithmetic never uses Float/Double.

**Failure handling:** Overflow → nil; invalid frame rate (denominator 0) → `assertionFailure` in debug, safe default in release.

**Behavior that must remain unchanged:** All existing `CMTime`-based playback, export, and review code continues unchanged until explicitly migrated.

**Acceptance:**
- `swift test --filter MediaTimeTests` passes for all standard rates incl. drop-frame.
- Repeated frame snap → unsnap cycles produce zero float rounding error.
- `swift build` succeeds.

### Additional item 3 — Type-safe track ordering (SceneTracks)

**What:** Replace flat track array concept with `SceneTracks`: explicit typed fields `overlay`, `main` (singleton `VideoTrack`), `audio`, making it structurally impossible to mix track kinds or misplace a track.

**Why:** OpenCut's `SceneTracks` replaces a flat track array with three explicit fields, preventing track-kind mixups at the type level.

**How:**
1. Define track-kind enums (`VideoTrack`, `AudioTrack`, `OverlayTrack`) and typed collections in `SceneTracks.swift`.
   - Invariant: `SceneTracks.main` is exactly one `VideoTrack` (singleton).
2. Provide insertion/removal helpers that maintain invariants (no audio clip on main video track, no video clip on audio track).
   - Precondition: clip has a defined media type before insertion.
   - Failure: inserting wrong-kind clip → throw `TrackError.wrongTrackKind` (do not silently insert).
3. Add a compatibility adapter so existing timeline code reads `SceneTracks` without rewriting all clip placement at once.
   - Behavior unchanged: existing flat-model timeline code keeps working via the adapter.

**Files:**
- New: `Sources/CompositorPro/Timeline/SceneTracks.swift`
- Modify: `Sources/CompositorPro/Models/Timeline.swift` — optional migration path only; keep existing flat model working alongside
- New: `Tests/CompositorProTests/Timeline/SceneTracksTests.swift`

**Preconditions:** Existing timeline model uses flat track array; `SceneTracks` is additive.

**Invariants:** `main` track count == 1. No clip on a track of mismatched kind.

**Failure handling:** Misplaced clip insertion throws; caller handles (no silent corruption).

**Behavior that must remain unchanged:** Existing flat track array model and all current clip placement code continue to work unchanged.

**Acceptance:**
- `swift test --filter SceneTracksTests` passes (track-kind separation, invalid-placement rejection, singleton main track).
- Compile-time impossible to place a video clip on an audio track (or vice versa) via the typed API.

### Additional item 4 — Diff-based ripple editing

**What:** Add a diff-based ripple engine: snapshot track intervals before/after an edit, compute vacated intervals (incl. cross-track moves), emit explicit `RippleAdjustment` values applied in one deterministic pass.

**Why:** OpenCut replaced inline ripple with a diff-based system in `src/lib/ripple/`, composable and testable, independent of the triggering command.

**How:**
1. Model a track as a sorted set of occupied intervals; snapshot before and after an edit operation (`RippleEdit.swift`).
   - Invariant: intervals are non-overlapping and sorted within a track.
2. Compute added/removed/vacated intervals; for elements moved to other tracks, emit cross-track adjustments.
   - Precondition: before/after snapshots cover the same track set.
3. Produce a list of `RippleAdjustment` (track, interval, delta) applied in a single deterministic pass after the command completes.
   - Invariant: identical before/after snapshots produce identical adjustment lists regardless of triggering command.
4. Wire one existing timeline edit tool (`remove_clips` or `move_clips`) through the engine as a prototype.
   - Behavior unchanged: if engine returns no adjustments, fall back to existing behavior (no change).

**Files:**
- New: `Sources/CompositorPro/Timeline/RippleEdit.swift`
- New: `Tests/CompositorProTests/Timeline/RippleEditTests.swift`

**Preconditions:** An existing timeline edit tool (`remove_clips` or `move_clips`) exists to prototype against.

**Invariants:** Adjustment list is deterministic for identical snapshots. No overlapping intervals after applying adjustments.

**Failure handling:** Empty snapshot diff → no adjustments (no-op). Engine failure → fall back to existing behavior, never partial application.

**Behavior that must remain unchanged:** Existing non-ripple edit tools and timeline behavior unchanged when ripple engine yields no adjustments.

**Acceptance:**
- `swift test --filter RippleEditTests` passes (same-track, cross-track, gap preservation).
- Ripple result deterministic for identical before/after snapshots regardless of triggering command.

### Additional item 5 — Timeline UX: keyframe lanes + independent X/Y + graph editor

**What:** Support per-property keyframe lanes, independently animatable Position X and Y, and a bezier `KeyframeCurve` easing model.

**Why:** OpenCut: keyframes copy/paste between elements; "expand keyframes" to per-property lanes; animate Position X and Y independently; bezier graph editor for keyframe curves.

**How:**
1. Split `Clip.transform.position` into independently animatable `positionX` / `positionY` with separate keyframe tracks (`Clip.swift`).
   - Precondition: existing `position` keyframes migrate to both X and Y (backward compatible).
   - Invariant: a clip with legacy single `position` still animates X and Y identically.
2. Add per-property lane expansion model: each animated property gets its own row under an expanded clip (`KeyframeLanes.swift`).
   - Invariant: collapsed clip shows one row; expanded shows one row per animated property.
3. Implement keyframe copy/paste (paste applies matching properties to target clip).
   - Failure: paste onto clip with no matching property type → no-op (do not crash).
4. Define bezier `KeyframeCurve` model (control points) for easing; keep rendering on existing keyframe system (`KeyframeGraph.swift`).
   - Behavior unchanged: existing keyframe rendering unchanged; curve model is additive.

**Files:**
- New: `Sources/CompositorPro/Timeline/KeyframeLanes.swift`
- New: `Sources/CompositorPro/Timeline/KeyframeGraph.swift`
- Modify: `Sources/CompositorPro/Models/Clip.swift` — add `positionX`/`positionY` independent keying
- New: `Tests/CompositorProTests/Timeline/KeyframeLaneTests.swift`

**Preconditions:** `Clip.transform.position` exists with keyframe support.

**Invariants:** Legacy `position` keyframes remain valid; `positionX`/`positionY` are additive. Curve control points clamped to valid range.

**Failure handling:** Copy/paste of mismatched property → no-op. Invalid bezier points → clamped, not rejected.

**Behavior that must remain unchanged:** Existing keyframe rendering and legacy single-position animation continue unchanged.

**Acceptance:**
- `swift test --filter KeyframeLaneTests` passes (copy/paste, expand lanes, independent X/Y, bezier encode/decode round-trip).
- Position X can animate at a different rate than Y on the same clip.

### Additional item 6 — Masks

**What:** Add `Mask` model (split/rectangle/ellipse/star/heart/diamond/cinematic bars with position/size/rotation/feather/stroke) and Core Image mask rendering per layer.

**Why:** OpenCut masks: hide/reveal parts of any video or image layer, with position, size, rotation, feather, stroke, drag handles in preview, properties panel controls.

**How:**
1. Define `Mask` Codable enum with all seven shapes + shared parameters, validated bounds (`Mask.swift`).
   - Invariant: feather ≥ 0, stroke ≥ 0; rejected at decode if violated.
   - Failure: invalid parameter → decode fails (throw), no silent default.
2. Add mask as optional property on clip/layer; a clip has at most one active mask (`Clip.swift` or layer model).
   - Invariant: at most one mask per clip; nil mask = no masking.
3. Implement mask rendering as a Core Image filter chain applied to the layer's output before compositing (`MaskRenderer.swift`).
   - Precondition: layer output available as CIImage.
   - Failure: CIFilter creation fails → render layer unmasked (do not crash).
4. Add preview overlay with draggable handles for mask frame/feather (UI skeleton only; no full manipulation yet) (`MaskOverlay.swift`).
   - Behavior unchanged: existing preview rendering unchanged when no mask present.

**Files:**
- New: `Sources/CompositorPro/Models/Mask.swift`
- New: `Sources/CompositorPro/Compositing/MaskRenderer.swift`
- New: `Sources/CompositorPro/Editor/MaskOverlay.swift`
- New: `Tests/CompositorProTests/Models/MaskTests.swift`

**Preconditions:** Clip/layer model supports optional properties; Core Image available.

**Invariants:** Mask parameter bounds validated at decode. At most one mask per clip.

**Failure handling:** CIFilter failure → unmasked render. Invalid mask JSON → decode error, not silent fallback.

**Behavior that must remain unchanged:** Layers without masks render exactly as before.

**Acceptance:**
- `swift test --filter MaskTests` passes (shape enum, parameter bounds, Codable round-trip).
- Invalid parameters (negative feather) rejected at decode.

### Additional item 7 — Canvas: backgrounds, custom size, preview zoom + pan

**What:** Support arbitrary custom canvas size, canvas backgrounds (none/solid/gradient/blur), and preview zoom + pan with clamping.

**Why:** OpenCut: canvas backgrounds (blur/solid/gradient), custom canvas size (not locked to presets), preview zoom and panning.

**How:**
1. Replace fixed canvas presets with arbitrary `CGSize` width/height entry; validate min/max bounds (`CanvasSettings.swift`).
   - Precondition: min/max size constants defined (e.g., min 160x90, max 7680x4320).
   - Failure: size out of bounds → clamp to nearest valid, do not crash.
2. Define `CanvasBackground` enum (none / solid color / gradient / blur) with parameters.
   - Invariant: `none` means transparent background (existing default behavior).
3. Add zoom scale + pan offset to preview view model; clamp pan to content bounds at current zoom (`RenderedTimelineReview.swift`).
   - Invariant: pan never allows content to drift fully out of view; zoom clamped to [0.25, 4.0].
4. Render canvas background behind timeline content in preview; blur background via CIFilter.
   - Behavior unchanged: existing preset canvas sizes still accepted; background defaults to none/transparent.

**Files:**
- New: `Sources/CompositorPro/Models/CanvasSettings.swift`
- Modify: `Sources/CompositorPro/Preview/RenderedTimelineReview.swift` — add zoom/pan state + background rendering
- New: `Tests/CompositorProTests/Preview/CanvasSettingsTests.swift`

**Preconditions:** Preview/render pipeline exists; `RenderedTimelineReview.swift` is the preview owner.

**Invariants:** Custom size persists and round-trips through Codable. Zoom/pan state is per-preview-session, not persisted to project (or persisted separately).

**Failure handling:** Out-of-range size → clamped. CIFilter blur unavailable → solid color fallback.

**Behavior that must remain unchanged:** Existing fixed preset canvases continue to work. Default background remains transparent/none.

**Acceptance:**
- `swift test --filter CanvasSettingsTests` passes (size validation, background kind decode).
- Custom canvas size persists and reloads; zoom/pan clamps correctly (content never fully out of view).

### Additional item 8 — Audio: RMS waveforms + volume/speed with maintain pitch

**What:** Add RMS-based waveforms (visible-range-only rendering), per-clip volume, speed rate, and "maintain pitch" toggle.

**Why:** OpenCut: RMS-based waveforms scaled and rendered only for visible range; volume control for audio/video; speed control with "maintain pitch" (no chipmunk/deepen).

**How:**
1. Implement RMS waveform computation over audio assets; cache per asset; compute/render only visible time range (`RMSWaveform.swift`).
   - Precondition: audio asset readable via AVFoundation.
   - Failure: asset unreadable → return empty waveform (silent), do not crash.
   - Invariant: waveform cache keyed by asset URL + visible range; recomputed when range changes.
2. Add per-clip `volume: Float` (0…2) and `speedRate: Float` with `maintainPitch: Bool` to the audio model (`AudioMixState.swift`).
   - Invariant: volume clamped to [0,2]; speedRate clamped to [0.25, 4.0].
3. Wire speed change through AVFoundation `rateAdjust` + pitch preservation when `maintainPitch` is true.
   - Behavior unchanged: `maintainPitch=false` preserves existing speed behavior (pitch shifts with rate).
4. Render waveform only for the visible timeline window in the timeline/audio panel.
   - Invariant: off-screen waveform not computed/rendered.

**Files:**
- New: `Sources/CompositorPro/Audio/Analysis/RMSWaveform.swift`
- Modify: `Sources/CompositorPro/Audio/AudioMixState.swift` — add `volume`/`speedRate`/`maintainPitch` per clip
- New: `Tests/CompositorProTests/Audio/RMSWaveformTests.swift`

**Preconditions:** `AudioMixState.swift` exists; AVFoundation audio asset reading available.

**Invariants:** Volume/speed are per-clip, do not mutate the source asset. Waveform computation off main actor.

**Failure handling:** Audio asset read failure → empty waveform. Invalid volume/speed → clamped.

**Behavior that must remain unchanged:** Source audio assets never mutated. Existing speed behavior (without maintain pitch) unchanged.

**Acceptance:**
- `swift test --filter RMSWaveformTests` passes (RMS values, visible-range slicing).
- Volume and speed change per clip without mutating source asset; maintain pitch toggles correctly.

### Additional item 9 — Captions: auto-captions + transcript file import

**What:** Add import of transcript files (.srt/.vtt/.txt) to generate captions instead of running auto-transcription.

**Why:** OpenCut: import transcript files to generate captions instead of running auto-transcription; auto-generated captions exist.

**How:**
1. Add file import button to captions tab; accept `.srt`, `.vtt`, `.txt` (`CaptionTab.swift`).
   - Precondition: captions tab exists; file picker available on macOS.
   - Failure: user cancels picker → no-op.
2. Parse transcript into time-stamped segments; handle missing timestamps (evenly distribute across duration) (`TranscriptImporter.swift`).
   - Invariant: SRT/VTT timestamp parsing handles `HH:MM:SS,mmm` and `HH:MM:SS.mmm`.
   - Failure: unparseable file → actionable error shown, no crash.
3. Offer user choice: import as captions directly, or run auto-transcription on imported text for refinement.
   - Behavior unchanged: existing auto-transcription flow unchanged.
4. Merge imported segments into existing caption track without duplicating overlaps.
   - Invariant: imported segments do not duplicate existing caption time ranges.

**Files:**
- Modify: `Sources/CompositorPro/MediaPanel/CaptionsTab/CaptionTab.swift` — add import action
- New: `Sources/CompositorPro/Captions/TranscriptImporter.swift`
- New: `Tests/CompositorProTests/Captions/TranscriptImporterTests.swift`

**Preconditions:** Caption tab and caption track model exist.

**Invariants:** No duplicate caption time ranges after merge. Missing timestamps evenly distributed.

**Failure handling:** Invalid/unsupported file → clear error message, no crash. Empty file → no segments added.

**Behavior that must remain unchanged:** Existing auto-generated caption flow unchanged. Existing captions untouched by import unless user merges.

**Acceptance:**
- `swift test --filter TranscriptImporterTests` passes for SRT/VTT/plain.
- Imported captions appear on timeline; invalid files show actionable error, no crash.

### Additional item 10 — Asset panel multi-select + timeline multi-select modifiers

**What:** Add multi-select to asset panel (⌘/Shift click, bulk delete) and timeline (Shift/Ctrl drag-select, Shift+click add-to-selection, Escape deselect, selection retention after drag/resize/move).

**Why:** OpenCut: multi-select assets in asset panel; Shift/Ctrl drag-select in timeline; Shift+click to add to selection; Escape to deselect; clips stay selected after drag/resize/move.

**How:**
1. Asset panel: track selected asset IDs; ⌘/Shift click toggles; bulk delete removes all selected (`MediaPanel/`).
   - Invariant: bulk delete removes exactly the selected set, no more/no less.
   - Failure: delete failure for one asset → continue with others, report failures.
2. Timeline: Shift+click adds to existing selection; Ctrl/Cmd drag selects range; Escape clears selection (`Timeline/`).
   - Invariant: Escape always clears selection regardless of modifier state.
3. After a clip drag, resize, or track move, the clip remains selected.
   - Behavior unchanged: fixes deselect-on-release bug class; existing move/resize logic otherwise unchanged.
4. Selection outline style consistent across asset panel and timeline.
   - Invariant: same outline color/width for selected items in both panels.

**Files:**
- Modify: `Sources/CompositorPro/MediaPanel/` — multi-select asset grid
- Modify: `Sources/CompositorPro/Timeline/` — Shift/Ctrl drag-select, add-to-selection, Escape deselect, retention
- New: `Tests/CompositorProTests/Timeline/TimelineSelectionTests.swift`

**Preconditions:** Asset grid and timeline selection models exist.

**Invariants:** Selection set is the source of truth; UI reflects it. Escape clears selection.

**Failure handling:** Bulk delete partial failure → continue, report. Modifier key state read reliably from event.

**Behavior that must remain unchanged:** Single-click selection and existing move/resize behavior unchanged; only adds multi-select and retention.

**Acceptance:**
- `swift test --filter TimelineSelectionTests` passes (add-to-selection, Escape deselect, retention after move).
- Bulk asset delete removes exactly the selected set; Escape clears timeline selection.

### Additional item 11 — Number inputs: math expressions + click-drag scrubbing + hold-Shift-to-unsnap

**What:** Add number input supporting math expressions (e.g., `1920/2`) and click-drag scrubbing; hold Shift to temporarily disable snap; trim handles outside clip; dashed selection outlines.

**Why:** OpenCut: number inputs support math expressions and click-drag scrubbing; hold Shift while moving/resizing to temporarily disable snapping; dashed selection outlines; trim handles outside clip.

**How:**
1. Implement `MathNumberInput` evaluating simple arithmetic expressions on commit; clamp to field min/max (`MathNumberInput.swift`).
   - Invariant: expression evaluator supports +,-,*,/, parentheses; no arbitrary code execution.
   - Failure: invalid expression → show previous valid value, inline error, do not crash.
2. Add click-drag scrubbing: drag left/right to increment/decrement by step, fine/coarse via modifier.
   - Invariant: scrub value clamped to field min/max.
3. Timeline: while Shift is held during move/resize, bypass snap-to-grid for that gesture only (`Timeline/`).
   - Precondition: snap-to-grid exists; modifier key state read from event.
   - Failure: modifier state unreadable → default to snapping (safe).
4. Move trim handles outside clip's visible rect; dashed selection outlines.
   - Behavior unchanged: clip's visible area still accurately represents start/end.

**Files:**
- New: `Sources/CompositorPro/UI/MathNumberInput.swift`
- Modify: `Sources/CompositorPro/Timeline/` — Shift-to-unsnap; trim handles outside clip bounds
- New: `Tests/CompositorProTests/UI/MathNumberInputTests.swift`

**Preconditions:** Existing number input field and timeline snap-to-grid exist.

**Invariants:** Expression evaluation is sandboxed (no eval of arbitrary code). Scrub/entry clamped to min/max.

**Failure handling:** Invalid expression → retain previous value + error. Modifier unreadable → snap by default.

**Behavior that must remain unchanged:** Existing number input without expressions works unchanged. Snap-to-grid default unchanged when Shift not held.

**Acceptance:**
- `swift test --filter MathNumberInputTests` passes (expressions, clamping, scrubbing).
- Shift-held gesture does not snap; trim handles no longer overlap clip interior.

### Additional item 12 — Bookmarks with notes + color labels + optional duration

**What:** Extend timeline markers/bookmarks with `note`, `colorLabel`, and optional `duration`.

**Why:** OpenCut: bookmarks support notes, color labels, optional duration to plan scenes.

**How:**
1. Extend marker/bookmark model with `note: String?`, `colorLabel: ColorLabel?`, `duration: TimeInterval?` (`Timeline.swift`).
   - Invariant: `nil` duration = point bookmark (existing behavior); non-nil = span.
   - Failure: missing optional fields in old project files → decode as nil (backward compatible).
2. Add bookmark create/edit UI (note field, color chip, optional duration toggle).
   - Behavior unchanged: existing bookmark creation without note/duration unchanged.
3. Render bookmarks on timeline ruler with color label + duration span.
   - Invariant: duration bookmark renders as a span; point bookmark renders as a marker.

**Files:**
- Modify: `Sources/CompositorPro/Models/Timeline.swift` — add `Bookmark` fields
- New: `Tests/CompositorProTests/Timeline/BookmarkTests.swift`

**Preconditions:** Timeline marker/bookmark model exists.

**Invariants:** Old project files without new fields decode gracefully (all optional).

**Failure handling:** Invalid color label → default color, no crash.

**Behavior that must remain unchanged:** Existing point bookmarks (no duration) render exactly as before.

**Acceptance:**
- `swift test --filter BookmarkTests` passes (note/label/duration, Codable round-trip, backward-compatible decode).
- Bookmark with duration renders as span; without duration renders as point.

### Additional item 13 — Blend modes + paste clipboard media

**What:** Add per-clip `blendMode` (Multiply/Screen/Overlay) and paste image/video/audio from NSPasteboard into media library/timeline.

**Why:** OpenCut: blend modes (Multiply, Screen, Overlay) per element; paste images/videos/audio from clipboard straight into editor.

**How:**
1. Add `blendMode` to clip compositing properties; apply via Core Image compositing operator at render (`Clip.swift`).
   - Invariant: blend mode `.normal` = existing behavior (no change).
   - Failure: unsupported blend mode → fall back to `.normal`, do not crash.
2. Pasteboard handler: detect `NSPasteboard.PasteboardType` (image/movie/audio), import to media library, offer insert at playhead (`PasteboardMedia.swift`).
   - Precondition: media library import pipeline exists.
   - Failure: unsupported pasteboard type → ignore silently (no error to user for non-media).
3. Paste of multiple items inserts each as a clip on the next available track.
   - Invariant: multiple items → multiple clips, ordered, on next available tracks.

**Files:**
- Modify: `Sources/CompositorPro/Models/Clip.swift` — add `blendMode`
- New: `Sources/CompositorPro/Media/PasteboardMedia.swift`
- New: `Tests/CompositorProTests/Media/PasteboardMediaTests.swift`

**Preconditions:** Clip compositing properties exist; NSPasteboard available on macOS.

**Invariants:** `.normal` blend mode equals no-blend existing behavior. Source pixels never altered by blend mode.

**Failure handling:** Unsupported blend mode → `.normal`. Unsupported pasteboard type → ignored.

**Behavior that must remain unchanged:** Existing clips without blendMode render exactly as before (`.normal`).

**Acceptance:**
- `swift test --filter PasteboardMediaTests` passes (pasteboard import by type).
- Pasting an image creates a clip; blend mode changes compositing output without altering source pixels.

### Additional item 14 — FFmpeg build matrix (reference only)

OpenCut pins FFmpeg 8.1.3 with prebuilt binary URLs + sha256 per platform in `crates/media/setup/ffmpeg.json`. Compositor Pro is AVFoundation-only with no FFmpeg dependency by design. Keep as reference only; do not add FFmpeg now (code-sign + notarization implications for a non-sandboxed Developer ID app). Decision recorded in `PLAN_OPENMONTAGE_INTEGRATION.md`: FFmpeg bundling deferred.

**Files:** None. No implementation unless FFmpeg is explicitly added later.

### Additional item 15 — Project storage migrations (reference pattern)

OpenCut ships 16 storage migration steps (v9–v25) covering schema changes. Compositor Pro already uses `ProjectPackageCoordinator` for `.compositorpro` package save/migration. Adopt OpenCut's versioned migration pattern only if project format versioning is added later.

Pattern: versioned migration steps keyed by format version, run on open, last-successful-state preserved on failure.

**Files:** None. No implementation unless project format versioning is added.

---

---

### Order of implementation (recommended)
1. **Item 1 — OKLCH theme** (lowest risk, visual upgrade, maps to `AppTheme`)
2. **Item 2 — MediaTime** (foundational for timeline rework)
3. **Item 4 — Diff-based ripple** (composable timeline algorithm)
4. **Item 3 — SceneTracks** (type-safe tracks, pairs with MediaTime)
5. Items 5–13 (timeline UX, masks, canvas, audio, captions, selection, inputs, bookmarks, blend/paste) — pick by user value
6. Items 14–15 — reference only, no implementation unless FFmpeg/project-versioning is added

All items follow AGENTS.md: keep one authoritative owner for mutable state, views render state and forward intent, expensive work/filesystem off main actor, validate bounds before mutation, surface success/failure, no `try?` swallowing, no secret logging.

- Task 10: graphic scenes persist their spec + renderer version on `EditPlan.graphicScenes`.
- Task 11: `plan_edit action=revise_section` resolves a section change across linked beats, timing, and dependents.
- Task 12: `review_timeline` reports bounded motion metrics (mean/min/max luma delta, frozen spans).
- Task 16: `ExportSignposts` emits prepare/export phase signposts + wall-clock timing.
- Fixed a SIGTRAP crash in the new motion sampler (raw pixel read assumed BGRA; now draws into a fixed RGBA8 buffer).

- Agent latency: targeted-edit tool subset, compact edit prompt, OpenAI prompt-cache key/TTL, direct tool path, skill-rescan skip. Payload ~245 KB → ~152 KB tools, ~37 KB → ~2.7 KB system. Real-provider wall-clock still unverified.
- Agent reasoning UI: raw reasoning hidden; live "Thinking…" then a one-line status per step.

## Notes

- `done.md` prose is aspirational in places (tasks 10–16 are checked with no verification record). Treat this file as the source of truth until `done.md` is reconciled.
- Nothing below the "Recently landed" line has a real-provider or human playback proof.
- OpenCut repo surveyed: `https://github.com/OpenCut-app/OpenCut` — mid-rewrite skeleton (TS web + Rust GPUI desktop + Cloudflare API), MIT licensed. Mature design described in `changelog/0.1.0`–`0.3.0.md` (`MediaTime` 120k ticks/sec, rational `FrameRate`, `SceneTracks`, diff-based ripple, Rust/wgpu WASM compositor). Referenced `rust/crates/` and `src/lib/ripple/` code is **not in this checkout** — treat as design reference only, do not copy.
- Compositor Pro is AGPL-clean: OpenCut is MIT, so adapting ideas/reimplementing in Swift is fine. Do not vendor OpenCut TS/Rust source.
- The pre-existing `CLIHandler.swift` compile failure blocks `swift build`/`swift test`; fix it before plugin item 4. Plugin items 1–3 do not depend on the CLI build.
