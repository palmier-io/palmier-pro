# Concurrency and executor safety

Read for tasks, actors, callbacks, gates, asynchronous state, or filesystem work.

## Ownership and execution

- Keep observable UI state and lightweight coordination on the main actor. Do not perform file access, decoding, inference, image processing, indexing, export, blocking framework setup, or large transforms there.
- `Task {}` inherits isolation. `async` and synchronous `nonisolated` do not switch executors. Synchronous `FileIO` and resource helpers require an off-main caller.
- Prefer asynchronous system APIs. Otherwise use a dedicated utility queue/service, an `@concurrent` async operation, or a bounded `Task.detached` over immutable `Sendable` snapshots.
- Snapshot the minimum actor-owned input, return a value, then publish on its owner. Do not capture a main-actor model inside a worker or mutate observation from the I/O executor.
- Never block the main thread with queue synchronization, semaphore/group waits, locks, polling, or synchronous waits for async work.
- Actors protect only their own state. Audit shared C/C++ libraries, Metal resources, AVFoundation objects, caches, and process-global state before allowing separate actors to call them concurrently.

## Suspension and lifecycle

- At every `await`, assume state changed. Revalidate project/timeline/asset identity, URL, generation, selection, configuration, lifecycle, eligibility, and cancellation as applicable before committing.
- Prefer structured concurrency. Store unstructured task handles when cancellation matters; define the owner, deduplication key, terminal state, and teardown behavior.
- Check cancellation before start, while waiting, between expensive chunks, after work, and before publication. Do not publish partial or stale results.
- Bound concurrency by the scarce resource: decoders, readers, exports, model inference, thumbnails, or filesystem destinations. Never create one task per item without a limit.
- Acquire gates before installing release `defer`; keep acquisition/release matched. Cancellation while queued must not leak a permit or resume twice.
- Keep continuation state in one isolation domain. Resume exactly once on success, failure, refusal, cancellation, and missing-target paths.
- Treat Objective-C and third-party callback isolation as untrusted unless documented. Hop explicitly to the owner and use `@Sendable` for crossing callbacks.
- Avoid `nonisolated(unsafe)` and unchecked `Sendable`. Any exception requires a concrete invariant and focused proof, not a compiler-silencing annotation.
- Cover project switching, close/quit, Save As, sleep/wake, deactivation, device changes, and stale completion for the affected operation.
- Preserve terminal diagnostics distinguishing cancellation, validation, missing media, framework failure, and internal invariant violations. Log operation, stable IDs, and lifecycle phase without secrets, raw prompts, or unnecessary filesystem details.

## Proof

- Coordinate concurrency tests with gates, continuations, or injected hooks; never rely on sleeps, polling, repeated races, or scheduling luck.
- Exercise cancellation and teardown through the owning API. Use Thread Sanitizer/concurrency diagnostics when applicable; report precisely what was checked.
- Package operations also require [project-package rules](project-packages.md); admitted I/O may finish despite cancellation, so rollback and cleanup must be awaited.

References: [Swift 6.2 concurrency](https://www.swift.org/blog/swift-6.2-released/), [executor/isolation guidance](https://developer.apple.com/videos/play/wwdc2025/268/), [data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/), and [task cancellation](https://developer.apple.com/documentation/swift/task/).
