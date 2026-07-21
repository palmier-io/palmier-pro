# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build

```bash
swift build
swift run
swift test
```

Use `swift build --traits BundledSpeech` for changes that touch MLX, speech analysis, transcription, or bundled speech resources.

## Engineering approach

- Understand the owning feature and existing abstractions before editing. Trace the complete call path, including UI, Agent tools, undo, persistence, and background work.
- For nontrivial changes, identify the source of truth, state owner, isolation domain, invariants, failure behavior, cancellation behavior, and file placement before writing code.
- Design the architecture before adding implementation details. Prefer a small coherent change over patches spread across unrelated layers.
- Keep one authoritative owner for mutable state. Derived state must be computed or maintained by a cache with an explicit invalidation contract.
- Reuse existing domain operations. Do not create a second implementation because the caller is a preview, SwiftUI view, AppKit controller, Agent tool, or test.
- Preview, validation, execution, persistence, and undo must share the same eligibility rules, calculations, clamping, timing, placement, and mutation helpers.
- Place code with the feature that owns it. Use `Utilities` only for infrastructure used by multiple independent features.
- Split extensions by coherent capability, not arbitrary file length. File and type names must make ownership clear.
- SwiftUI views render state and forward user intent. Keep domain mutations, filesystem work, media processing, and orchestration out of view bodies.
- Follow the Swift API Design Guidelines. Optimize names for clarity at the call site and use established filmmaking and Apple-platform terminology.

## Code style

- Keep comments minimal. Write one only when the why, invariant, safety constraint, or framework workaround is non-obvious.
- Comments are one short line maximum. Do not narrate code, restate names, describe the current patch, leave removal breadcrumbs, add commented-out code, or write paragraph docstrings for internal APIs.
- Prefer precise names, small types, and extracted operations over explanatory comments.
- Complex logic must have a single source of truth. Never copy a calculation or business rule into another file or surface.
- Remove dead code, unused state, obsolete compatibility paths, and temporary diagnostics before finishing.
- Do not add compatibility code for OS versions or architectures Palmier Pro does not support.

## Concurrency and the main actor

- Treat the main actor as a scarce UI resource. It may own UI state and lightweight coordination state, but it must not perform file I/O, media decoding, model inference, image processing, indexing, export work, blocking framework calls, or large collection transforms.
- `@MainActor` provides isolation, not performance. Move expensive work out of a main-actor type instead of assuming an `async` method makes it safe.
- `Task {}` inherits actor isolation. Never use it as evidence that synchronous work moved off the main actor.
- `nonisolated` on a synchronous function does not switch threads. A call from the main thread still runs on the main thread.
- Make executor changes explicit. Prefer an asynchronous system API; otherwise use a dedicated utility queue or service, an `@concurrent` async function, or a carefully bounded `Task.detached` over immutable `Sendable` snapshots.
- Snapshot the minimum immutable input before leaving an actor. Return a value, then apply it on the owning actor after checking cancellation and confirming the result is still current.
- At every `await`, assume actor-isolated state may have changed. Revalidate identity, generation, configuration, selection, lifecycle state, and preconditions before committing a result.
- Prefer structured concurrency. Unstructured tasks must have a clear owner, stored handle when cancellation matters, and teardown behavior.
- Cancellation is cooperative. Long operations and loops must check cancellation at useful boundaries, and cancellation must not commit partial or stale results.
- Bound parallel work according to the actual scarce resource. Do not create one task per asset, frame, thumbnail, decoder, or model request without a concurrency limit.
- Deduplicate identical in-flight work where multiple callers can request the same result.
- Actors protect their own state only. Audit process-global state, C/C++ libraries, Metal resources, AVFoundation objects, caches, and third-party dependencies before allowing separate actors to call them concurrently.
- Acquire and release gates in matched scopes. Install `defer` only after acquisition succeeds. Make cancellation while waiting safe.
- Keep continuation state in one isolation domain and resume every continuation exactly once on success, failure, or cancellation.
- Never block the main thread with `DispatchQueue.sync`, semaphore waits, group waits, locks, polling, or synchronous waits for async work.
- Treat Objective-C and third-party callback isolation as untrusted unless documented. Hop explicitly to the correct actor and use `@Sendable` where a callback crosses isolation.
- Avoid `nonisolated(unsafe)` and unchecked `Sendable`. Any use requires a concrete invariant and targeted coverage.

## File I/O and project packages

- Every filesystem operation must execute off the main actor and main thread. This includes reads, writes, encoding to or decoding from disk, existence checks, metadata and resource-value queries, directory enumeration, coordination, copying, moving, replacing, deleting, and directory creation.
- Assume every volume can be slow, removable, externally modified, or network-backed. File size and a successful previous access do not make synchronous main-thread access safe.
- Prefer asynchronous APIs. Run synchronous Foundation file APIs behind an explicit background boundary, preferably a dedicated serial utility queue for coordinated operations.
- The synchronous `FileIO` helpers do not provide an execution hop. Callers are responsible for invoking them from an off-main context.
- Snapshot actor-owned model data before file work. Do not capture a main-actor model or mutate observable state from the file-I/O executor.
- Stage complete output outside the live project package, prepare replacements on the destination volume, and atomically install the finished item.
- Route all live `.palmier` package media installs and removals through `ProjectPackageCoordinator`. Do not write directly into a live package from feature code.
- Serialize operations that target the same package or destination. A save, import, generation result, thumbnail, removal, export, and close operation must not race each other.
- Closing, Save As, and app termination must wait for admitted mutations, reject late commits, and preserve the latest successful state.
- Use unique temporary paths and clean them on success, failure, and cancellation. Never delete or replace a destination until the complete replacement is ready.
- Surface user-requested file failures. Do not hide them with `try?`, empty results, or success-shaped responses.

## Performance

- Treat rendering, playback, scrubbing, audio metering, timeline input, SwiftUI view updates, import, indexing, restore, save, and export as performance-sensitive paths.
- Do not perform filesystem access, logging, JSON encoding, model setup, decoder or reader creation, audio-graph setup, LUT parsing, `CIContext` creation, or other blocking setup inside per-frame, per-sample, per-grain, per-item view, or repeated interaction paths.
- Measure before claiming a performance improvement. Use the relevant Instruments template, signposts, a focused benchmark, or a performance test, then compare before and after under the same workload.
- Fix algorithmic complexity and unnecessary work before applying low-level optimizations. Watch for nested scans, repeated sorting, copy-on-write mutation in loops, intermediate arrays, repeated actor hops, and repeated observation invalidation.
- Batch and coalesce bulk mutations. Preserve explicit consistency boundaries by flushing pending state before save snapshots, undo snapshots, export, close, and reads that promise current data.
- Load and hydrate media lazily. Do not decode thumbnails, waveforms, filmstrips, metadata, transcripts, or models until a consumer needs them.
- Cache expensive reusable work only with an explicit key, capacity, invalidation rule, replacement rule, lifecycle behavior, and stale-result policy.
- Reuse expensive AVFoundation, Core Image, Metal, audio, and model objects when their documented lifecycle permits it. Invalidate them on relevant configuration and application lifecycle changes.
- Keep high-frequency observable state as narrow as possible. A progress counter, meter, or playhead update must not invalidate an entire panel or large media grid.
- Keep SwiftUI `body` work fast and side-effect free. Precompute expensive derived data and observe the smallest state surface that can render the result.
- Limit retained media and cache memory. Use bounded caches, release temporary buffers promptly, and use scoped autorelease pools for large Objective-C media loops when profiling shows retained temporaries.
- Keep per-item success logging out of release hot paths. Production logs should preserve actionable warnings, failures, and batch summaries without evaluating verbose messages unnecessarily.

## Correctness and edge cases

- “Works on the happy path” is not sufficient. Before implementing, enumerate the applicable boundary, lifecycle, concurrency, and failure cases and decide which layer owns each behavior.
- Validate empty, nil, zero, negative, maximum, overflowing, non-finite, malformed, duplicated, missing, stale, and unsupported inputs as applicable.
- Validate before integer arithmetic, frame addition, duration multiplication, indexing, or numeric conversion. Never rely on a later `do`/`catch` to catch a Swift arithmetic trap.
- Define exact rounding and clamping behavior. Do not silently clamp an invalid request unless tolerance is an intentional documented part of the contract.
- Cover no-op and repeated operations. They must report accurately and must not create mutations, undo entries, duplicate work, or misleading success.
- Consider cancellation before start, during each phase, after work completes but before commit, and while waiting for a gate or callback.
- Consider stale completion after selection, timeline, project, asset URL, model, mix, generation, or configuration changes.
- Consider close, quit, sleep, wake, app deactivation, device changes, Save As, and teardown while work is active.
- Consider empty timelines, zero-duration media, missing tracks, corrupt or offline media, variable frame rates, non-integer speeds, time-scale conversion, and long-duration projects.
- Consider linked clips, nested timelines, multicam groups, locked or sync-locked tracks, split clips, overlapping clips, and changes to a child timeline after a carrier was created.
- Consider interaction combinations: keyboard modifiers, Escape, dismissal, mouse-up after cancellation, disabled controls, focus changes, selection changes, and overlapping gestures.
- Consider partial filesystem failure, permissions, an existing destination, identical source and destination, external changes, low space, and cleanup failure.
- Preserve project invariants on every failure path. Partial success must either be safely resumable and reported as such or rolled back.

## Editor mutations and undo

- Route UI and Agent edits through the same domain mutation operations and shared `EditorUndo` history.
- One coherent user intent should produce one undoable action. Do not expose internal substeps as separate undo entries unless they are independently meaningful to the user.
- Validate arguments and preconditions before opening an undo group. Failed, cancelled, refused, and unchanged operations must not create empty undo steps.
- Nested implementation work must coalesce into the outer user action without closing groups owned by AppKit or another subsystem.
- Undo must restore exact state without cumulative frame rounding, derived-state drift, orphaned linked clips, or stale selection.
- Test interleaving between UI edits, Agent edits, automatic AppKit event grouping, project switching, and concurrent tool requests when the change touches undo.

## Agent tool design

- Design tools from user intent, not from internal APIs, database operations, view models, or service method boundaries.
- Start with representative user requests and define the desired outcome, success criteria, warnings, failure behavior, cancellation behavior, retry behavior, idempotency, and undo semantics before defining the schema.
- A tool should perform one coherent filmmaker action. One call should normally complete one atomic, understandable, and undoable workflow.
- Do not force the Agent to reproduce application orchestration by chaining low-level tools when Palmier Pro can safely perform the workflow itself.
- Do not create a broad “god tool” with unrelated modes. Group operations only when they share one user goal, validation model, and result shape.
- Express parameters in filmmaking and user-facing domain concepts. Hide storage layout, framework objects, UI state, and incidental implementation details.
- Use stable entity IDs for automation. Positional indexes and display labels may be returned for context but must not be the only durable identity after edits.
- Treat every tool argument as untrusted. Require exact types, finite numbers, explicit bounds, valid identifiers, and supported combinations before mutation or arithmetic.
- Resolve and validate the full request before mutating state. Apply multi-entity changes atomically and preserve all editor invariants.
- Reuse the same domain operation as the UI. Agent tools must not duplicate timeline math, placement, linking, sync, media, export, or project logic.
- Return structured receipts describing what changed, stable IDs, explicit no-op state, warnings, skipped items, and actionable errors. Do not return a success-shaped response when the requested outcome was adjusted or not achieved.
- Do not silently clamp, retarget, reorder, fall back, or select a different entity unless the tool contract explicitly promises that behavior and reports it.
- Long-running tools must expose a durable job or terminal result that the Agent can inspect. Asynchronous failure must not disappear after the initiating call returns.
- Keep Agent and MCP protocol values stable and machine-facing. Localize UI copy separately; do not serialize localized labels, errors, statuses, or undo names into tool contracts.
- Tool descriptions must explain when and why to use the tool, important constraints, and interactions with other tools. Do not merely restate parameter names.
- Refactoring internal APIs must not require changing a well-designed tool contract unless the user-visible capability changes.

## AVFoundation and media processing

- Use AVFoundation asynchronous property loading. Do not access deprecated synchronous `AVAsset`, `AVAssetTrack`, or `AVMetadataItem` properties that may block the calling thread.
- Keep exact media time in `CMTime` or frame-domain integers as long as possible. Convert to `Double` only at explicit UI or external-format boundaries.
- Define and preserve time scale, rounding, source-versus-timeline time, speed, trim, transform, color, alpha, audio layout, and metadata semantics.
- Keep potentially blocking AVFoundation and Core Audio setup and control calls off the main thread, even when the API does not advertise itself as file I/O.
- Reuse readers, render contexts, audio graphs, and pipelines where appropriate. Do not rebuild them during continuous interaction unless invalidation requires it.
- Bound concurrent decoders, readers, exports, model inference, thumbnail generation, and waveform extraction.
- Propagate cancellation through decode, render, inference, export, and generation loops. Check between chunks when an underlying synchronous API cannot be cancelled.
- Preserve source color attachments, transforms, frame timing, channel layout, and other media metadata unless the feature explicitly changes them.
- Test with missing audio or video tracks, unusual containers, zero or indefinite duration, rotated media, alpha media, nonstandard sample rates, and cancellation.

## SwiftUI and AppKit

- Keep observable UI state on the main actor and make background results cross that boundary as immutable values.
- Scope observation to the smallest view that needs the value. High-frequency progress, meter, hover, and playback state must not invalidate unrelated view trees.
- Do not start persistent side effects from `body`. Use lifecycle-aware tasks or controllers with explicit cancellation and teardown.
- Preserve native Mac behavior for keyboard focus, Escape, Return, menus, window restoration, undo, drag state, sheets, and close confirmation.
- AppKit delegate and completion-handler contracts must complete exactly once on every success, failure, cancellation, and missing-target path.
- Do not assume an AppKit or AVFoundation callback arrives on the main thread unless the API guarantees it.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/PalmierPro/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/PalmierPro/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Resources and configuration

- Resource lookup must work in the packaged app, `swift run`, and SwiftPM tests. Use the repository's shared resource lookup abstraction instead of inventing feature-specific probing.
- Treat the main bundle, SwiftPM resource bundle, and test bundle layouts as distinct configurations that require verification.
- Do not use `#if DEBUG` to select a fundamentally different resource path or user behavior unless the difference is intentional and tested.
- When adding a bundled resource, update `Package.swift`, bundle scripts, and tests as required. Verify the final `.app` layout when packaging behavior changes.
- Keep optional feature-trait code buildable both with and without the trait.

## Errors, logging, and observability

- Every user-initiated or Agent-initiated operation must reach an observable success, failure, refusal, or cancellation state.
- Do not use `try?` at an interaction boundary when failure changes the outcome. Convert the error into UI state, a tool error, a job failure, or an actionable log as appropriate.
- Fire-and-forget work is allowed only for explicitly best-effort behavior. It must not own required persistence or mutation, and failures must be safely ignorable or recorded.
- Log failures with the operation, stable entity IDs, lifecycle phase, and useful dimensions. Avoid secrets, API keys, credentials, raw user prompts, and unnecessary filesystem details.
- Preserve enough terminal diagnostics to distinguish cancellation, validation failure, unavailable media, framework failure, and internal invariant violation.
- Use assertions for programmer invariants, not recoverable user input, external files, lifecycle races, or Agent requests.

## Tests

- Unit tests must be concise and focused on behavior. One test should establish one invariant or regression, with only the setup needed to make that behavior clear.
- Prefer Swift Testing, `#expect`, and `#require` for new unit coverage unless an AppKit or XCTest-specific API requires XCTest.
- Use descriptive test names that state the behavior. Do not add comments that narrate arrange, act, and assert steps.
- Use parameterized tests for boundary matrices and repeated input/output cases instead of duplicating test bodies.
- Reuse small fixture builders for timelines, clips, media, projects, and temporary packages. Do not copy large setup graphs across suites.
- Test through the smallest stable public or internal seam that proves the behavior. Avoid tests coupled to private implementation details or incidental call counts.
- Every bug fix needs a regression test that fails for the original defect when practical.
- Test relevant negative paths: validation, no-op, partial failure, cancellation, stale completion, cleanup, and invariant preservation.
- Concurrency tests must coordinate deterministically with gates, continuations, or injected hooks. Do not rely on sleeps, timing luck, repeated loops, or task scheduling order.
- Tests run in parallel by default. Do not share mutable global state, fixed temporary filenames, ports, caches, defaults, or project directories between tests.
- Use unique temporary directories and clean them up. File-I/O test helpers must follow the same off-main rule as app code.
- Keep network, production credentials, external services, and the user's real files out of unit tests.
- Use performance tests only with a stable representative workload and an assertion that can detect a meaningful regression.

### Test responsibilities

- **UI testing:** UI behavior requires manual user verification. The Agent must provide a short test plan with setup, actions, expected results, and relevant edge or lifecycle cases. Do not claim the UI passed until the user confirms it.
- **Unit testing:** The Agent owns writing and running focused unit or regression tests. Run the smallest relevant suite while iterating and the broader affected suites before finishing.
- **MCP/Agent testing:** Agent tool changes require end-to-end verification through the MCP boundary, not only direct calls to internal Swift methods. Use connected MCP tools directly when available, or run the MCP server and use a temporary script or client to exercise it.
- MCP tests must verify the requested outcome independently by reading state back, inspecting the timeline or project, checking persistence, or exercising undo. Do not trust a success response as the sole proof.
- Cover tool discovery and schema when they change, representative user-intent requests, validation failures, no-op receipts, multi-step invariants, cancellation or asynchronous completion, and stable IDs.
- Use an isolated test project, temporary data, and a non-conflicting server port for MCP tests. Never mutate a user's real project as test setup.
- If an environment prevents an end-to-end test, state the exact blocker and give the user a concrete manual verification plan. Do not substitute a narrower test while claiming end-to-end coverage.

## Code reviews

- Review for correctness before style. Trace the changed behavior through its callers, shared state, background work, persistence, undo, UI, and Agent surfaces.
- Prioritize findings that can cause data loss, project corruption, crashes, hangs, races, security or privacy exposure, incorrect edits, broken undo, or misleading success. Then consider performance, maintainability, and polish.
- Verify the change preserves the feature's invariants on success, failure, cancellation, no-op, retry, and teardown paths.
- Look for main-actor work that can block: file access, media loading, synchronous framework calls, decoding, inference, export, indexing, large transforms, waits, and lock contention.
- Do not accept `Task {}`, `async`, or synchronous `nonisolated` code as proof that work is off-main. Follow the executor path.
- Look for concurrency mistakes: state read before an `await` and committed afterward without revalidation, unowned tasks, missing cancellation checks, unbounded fan-out, unbalanced gates, double-resumed continuations, callbacks on the wrong actor, and teardown racing active work.
- Check whether separate actors still touch shared process-global or non-thread-safe framework state.
- Review every filesystem mutation for staging, atomic replacement, same-destination serialization, cleanup, error propagation, package-save coordination, Save As, close, and termination behavior.
- Look for duplicated domain logic. Preview, validation, commit, undo, UI, and Agent paths must not implement slightly different eligibility, timing, clamping, placement, linking, or mutation rules.
- Check scaling against large projects and long timelines. Flag repeated filesystem metadata reads, nested scans, per-item observed mutations, eager hydration, repeated decoder setup, broad SwiftUI invalidation, unbounded caches, and excessive release logging.
- Review caches for complete keys, capacity limits, invalidation, replacement races, lifecycle reset, stale-value selection, and behavior when the backing file or configuration changes.
- Validate boundary arithmetic and conversions before use. Check zero, negative, maximum, overflow, non-finite, rounding, time-scale, index, and duration cases.
- Review editor changes with linked clips, nested timelines, multicam groups, locked tracks, missing media, empty timelines, unusual track layouts, and current selection or focus changes.
- Review UI interactions across mouse, keyboard modifiers, Escape, dismissal, disabled state, focus, app deactivation, sleep, and mouse-up after cancellation. Preview state must match committed state.
- Review undo boundaries. Validation must happen before grouping; failed and unchanged operations must not add undo entries; one user intent must undo as one action without absorbing adjacent edits.
- Review Agent tools from the user's requested outcome. Reject schemas that mirror internal APIs, require fragile low-level orchestration, use unstable positional identity, silently adjust requests, duplicate UI domain logic, or omit structured receipts and terminal failures.
- Keep localized UI language separate from stable Agent and MCP contracts, serialized state, identifiers, and machine-readable errors.
- Check AVFoundation work for asynchronous property loading, exact time math, cancellation, bounded readers or decoders, lifecycle invalidation, and preservation of source transforms, color, alpha, timing, and audio metadata.
- Treat swallowed errors, recoverable-input assertions, `try?` at interaction boundaries, unchecked casts, `nonisolated(unsafe)`, and unchecked `Sendable` as review targets requiring proof.
- Verify tests reproduce the defect or protect the invariant, cover the important negative or interleaving path, remain deterministic and parallel-safe, and avoid duplicative setup.
- Verify stated build, test, runtime, and performance evidence matches what was actually run. Do not accept performance claims without comparable measurements.
- Keep findings actionable and evidence-based. State the triggering scenario, violated invariant, user impact, and relevant code path. Distinguish correctness defects from optional improvements.
- Review changed code and the directly affected system. Do not block a patch on unrelated pre-existing issues unless the change makes them reachable or more severe.

## Verification

- Run `swift build` after source changes.
- Run focused tests for the changed behavior. Run `swift test` for core editor, persistence, undo, concurrency, shared infrastructure, or broad refactors.
- Run `swift build --traits BundledSpeech` for speech, MLX, transcription, or bundled-model changes.
- For concurrency changes, exercise cancellation and lifecycle paths and use Thread Sanitizer or concurrency diagnostics when applicable.
- For responsiveness and performance changes, verify with Instruments or a focused measurement under a representative large workload.
- For UI interaction changes, run the app and verify mouse, keyboard, Escape, focus, undo, disabled, and empty states relevant to the change.
- For project-package changes, verify save, autosave, Save As, close, quit, failure, and concurrent media mutation paths.
- Report exactly what was run and what was not. Do not claim a full build, test, package, or runtime verification when only a subset completed.

## Git and pull requests

- Commit and PR titles use a concise lowercase category prefix in brackets, followed by an imperative summary: `[fix] Prevent stale export completion`.
- Use the narrowest accurate category, such as `[fix]`, `[perf]`, `[feat]`, `[agent]`, `[ui]`, `[refactor]`, `[test]`, `[docs]`, `[build]`, `[ci]`, `[telemetry]`, or `[cleanup]`. Combine categories only when both are essential, for example `[fix/perf]`.
- Keep commits focused. Do not mix unrelated cleanup or formatting into a feature or fix commit.
- PR bodies must include:
  1. **Summary:** what changed, the issue or user impact, and why the change is needed.
  2. **Approach:** important design decisions, technical details, invariants, tradeoffs, and alternatives rejected.
  3. **Design:** for large architectural changes, Mermaid diagrams showing the relevant before and after data flow, ownership, or lifecycle.
  4. **Testing:** exact automated commands and results, plus end-to-end UI or MCP scenarios, expected outcomes, and any verification not completed.
  5. **Change statistics:** aggregate additions and deletions by category, including code logic and tests.
- Describe the full resulting change, not the sequence of edits made while developing it. Remove stale investigation notes and unsupported claims.
- Open substantial changes as draft PRs until automated checks pass and required manual UI verification is identified or completed.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the product needs to ask for action, lead with the action verb; when it reports state, name the thing.

## Primary references

- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)
- [Improving performance and stability when accessing the file system](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)
- [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
- [Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/)
- [Swift concurrency data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)
- [Task cancellation](https://developer.apple.com/documentation/swift/task/)
- [Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)
- [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
- [Loading media data asynchronously](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously)
- [Swift Testing](https://developer.apple.com/documentation/testing)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
