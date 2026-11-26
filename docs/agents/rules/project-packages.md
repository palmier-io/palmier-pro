# Project packages and document lifecycle

Read for package I/O, media publication/removal, open/save/close, Save As, or generation commits.

## Owners and admission

- `Sources/CompositorPro/Project/VideoProject.swift` owns native document saves and close preparation. The editor's `ProjectPackageCoordinator` owns mutation admission, save fences, and lifecycle state; `ProjectPackageIO` owns the serial utility executor.
- Read the ownership, mutation, save, and close sections of `docs/contracts/project-package-lifecycle.md`, plus the specific affected contract. Historical verification notes are not proof of the current checkout.
- Route all live `.compositorpro` and legacy `.palmier` package media installs/removals through `ProjectPackageCoordinator`; do not write directly from feature code.
- Acquire admission before resolving the current destination and revalidate identity/eligibility after waiting. Keep a lease through publication, terminal failure, and awaited cleanup.
- Serialize work targeting the same package/destination. Save, import, generation, thumbnail, removal, export, and close must not race.

## Files and transactions

- Every filesystem operation runs off-main: existence/resource-value queries, metadata, enumeration, reads/writes, encoding/decoding, coordination, directory creation, copying/moving/replacing/deleting, and cleanup.
- Assume slow, removable, network-backed, externally changed volumes. File size and prior access do not justify synchronous main-thread I/O.
- Snapshot model data before file work. Use asynchronous APIs or the shared serial utility executor for synchronous Foundation calls; `FileIO` itself does not hop executors.
- Produce complete output in a unique stage outside the live package, prepare on the destination volume, then install atomically through the owning coordinator. Never delete/replace a destination before a complete replacement is ready.
- Respect the coordinator's create-new media installation and stage-ownership contract. Do not pass live package files as disposable owned stages or delete output another transaction owns.
- Revalidate cancellation, source/destination identity, lifecycle, and configuration before publishing model state. Roll back unpublished output and await cleanup on failure, refusal, and cancellation.
- Preserve imported/external source policy and backing bytes required by redo or existing timeline references. Removing a library record is not authorization to erase source media.
- Surface original failure and cleanup failure together. Do not hide user-requested file failures behind `try?`, empty results, or success-shaped responses.

## Saves and teardown

- Save/autosave snapshots include admitted successful mutations and flushed derived state. FIFO fences must not wait for queued work that cannot enter until the fence opens.
- Hold Save As coordination through installation and URL/undo rebasing. Queued work resolves the new destination only after admission.
- Close and termination reject new work, drain admitted mutations/saves and owned tasks, preserve the latest successful state, and reject late publication. Gate every project before awaiting the first during quit.
- Cancellation/refusal/final-save failure must leave invariants intact and recoverable admission/tasks in the intended state. Native delegate/completion contracts finish exactly once.
- Cover permissions, low space, partial failure, identical source/destination, collisions, path aliases, external changes, cancellation at each phase, stale source, and cleanup failure as applicable.
- Verify save, autosave, Save As, reopen/readback, undo/redo, close/quit, failed/cancelled close, and concurrent media mutation using disposable packages. A successful save callback alone is not persistence proof.

Reference: [filesystem performance and stability](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system).
