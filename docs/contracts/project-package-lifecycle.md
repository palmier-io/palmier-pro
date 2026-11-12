# Project package lifecycle

## Ownership

`VideoProject` owns native document saves and close preparation. Its editor owns one main-actor `ProjectPackageCoordinator`. The coordinator owns mutation admission, FIFO save fences, asynchronous media-operation handles, and the open/closing/closed state. The document and coordinator share one `ProjectPackageIO` serial utility queue.

`GenerationService` owns remote submission, subscription, and download tasks. Remote monitoring does not hold a package lease indefinitely. Each local download acquires its own lease and completes publication, metadata finalization, completion callbacks, and cleanup before releasing it.

Leases cannot be exchanged between coordinators or reused after their scope ends. Feature code does not write into a live package directly.

## Mutation contract

1. Acquire a lease with `withMutation`, or submit an owned UI operation with `startMutation`.
2. Resolve the current package and revalidate source identity and request eligibility after admission.
3. Produce a uniquely named staged file outside the live package, off-main. The producer owns cleanup until it transfers the stage to `commitStagedProjectMedia`.
4. Transfer ownership to the installer. It validates the lease, filename, source state, regular-file stage, and optional size limit.
5. Copy the complete stage to a unique sibling of the package on the destination volume, then move it into `media` with create-new semantics. Existing media is never replaced.
6. Await stage cleanup, then revalidate cancellation, source state, lease, and package identity. Publish model state synchronously on the main actor.
7. Release the lease only after publication or observable failure and awaited rollback cleanup.

The installer removes only transaction-owned unpublished output. A file already inside the live package cannot be passed as an owned stage. A stale source, removed placeholder, cancellation, collision, or changed destination prevents publication. Cleanup failure is returned together with the original error; it is not ignored or reported as success.

Filesystem operations, image encoding/decoding, and synchronous package writing run on an explicit background executor. `ProjectPackageIO.perform` deliberately finishes an admitted filesystem operation even if its awaiting task is cancelled; callers check cancellation at transaction boundaries and await cleanup. `write` is restricted to an off-main AppKit worker and synchronously enters the same serial queue.

Finder imports preserve external-source policy: scanning and metadata finalization are coordinated, but backing files remain external rather than being copied into the package. Removing a library record or undoing an import retains its installed backing bytes for redo and existing timeline references.

## Save fences

Calling `save` installs a fence synchronously. Already-granted mutations finish file work, model publication, and cleanup before the save snapshot is captured. Mutations waiting behind a fence are not counted as active; otherwise the save would wait for work that can only run after that save.

Save requests run FIFO. No queued mutation can enter between consecutive queued saves. Save completion callbacks run while the current fence remains held; a callback may enqueue another save without overlapping the current save context.

`VideoProject` publishes one immutable `SaveContext` before calling `super.save`. Only the AppKit save worker reads it; the main actor clears it after the native completion returns. This is the invariant behind its `nonisolated(unsafe)` handoff. Timeline, manifest, plans, and chat sessions are encoded off-main with per-call encoders. Encoding failures throw before package writing begins. AppKit supplies safe-save staging and installation; failed encoding must preserve the last successful package.

`writeSafely` unblocks native user interaction before AppKit prepares its safe-save directory. `write` also unblocks before checking its context. Direct main-thread writes and off-main writes without a coordinated context fail; there is no fallback snapshot or main-thread write path.

Save As holds the fence through native destination installation and URL rebasing. A queued mutation resolves its destination only after admission, so it targets the rebased package without retries. An already-granted mutation completes against the old package before Save As snapshots and copies it.

## Close and termination

Native `canClose` gates new admissions synchronously before scheduling asynchronous preparation. Close preparation cancels and drains Agent work, suspends and drains owned generation tasks, waits for admitted package work and saves, then performs a final save even when the native edited flag is clear. Preparation requests share one stored task.

Granted media operations may finish while closing. Queued and new mutations are refused. If final save or native close approval fails, admission reopens and recoverable generations resume. Actual `close` requires a drained closing coordinator and marks it closed before teardown. Creation failures use `abortOpening` to drain without requiring a successful final save.

Application termination must gate **every** project before awaiting preparation of the first project. A synchronous `close()` call cannot replace this protocol.

## Integration status

- Audio finalization now uses `withMutation` and revalidates source bytes/timeline after admission. No compatibility methods remain.
- Failed project creation awaits `abortOpening()` before off-main cleanup. New package reservation uses staged create-new installation; existing destinations are not deleted.
- Application termination synchronously gates all projects before its first await. Opening/creating projects is refused while termination is pending.
- The installer establishes stage ownership before any throwable cancellation/lease check and resolves symlink aliases off-main. Refusal cannot delete a live source. An owned task canceled before entry publishes its terminal failure before releasing the save fence.
- Manifest source classification requires the package path plus a slash boundary. Sibling names sharing a package prefix stay external; the package root cannot become an empty relative media path. All five pure-model regression cases passed in frozen focused gate 5.
- Generation initiation now throws before placeholder creation when canceled, suspended, or closing. Owned tasks publish terminal cancellation and retain received acknowledgments; integrated compilation and regression proof remain pending. Backend reconciliation remains separate.
- Documents inject their registry into the editor. Production open/create awaits shared-registry loading before stable-ID lookup; standalone editors never access it implicitly. Native Save As awaits registry `flush()`. Fixtures use isolated registry files; native readback and failure tests remain unrun.
- Document close cancels thumbnail/restore work before draining; canceled close restarts lazy hydration and pending generations. Restore tests await coordinator idle and preserve unused metadata instead of eagerly decoding it. An off-main actor now owns thumbnail generation and cancellation through its terminal callback.
- Coordinated close drains late saves and confirms removal from the document controller before navigation or MCP rebinding. Isolated close/refusal, native late-save, and cancellation tests are authored; integration is pending. [Contract and quit blocker](project-close-confirmation.md).

### Remote submission without acknowledgment

The backend can accept and charge for a submission before the client receives its job ID. If cancellation, connection loss, or process exit interrupts that acknowledgment, local state has no durable backend ID to monitor or resume. Draining local tasks cannot recover an ID that never arrived, and automatically resubmitting could create a second paid job. Submission failure or cancellation is not evidence that the backend rejected the request. Backend idempotency or submission reconciliation is required to close this gap; this prerequisite does not implement either.

## Automated proof and limits

Current verification host uses Apple Swift 6.4.2, targeting arm64 macOS 27.2; the package still declares Swift tools 6.2 and macOS 26. Builds on this host do not independently prove the Swift 6.2 toolchain or macOS 26.0 runtime.

New tests use unique off-main fixtures, actor signals, and a worker-only safe-write gate instead of sleeps or scheduler polling. They cover save fencing, FIFO requests, reentrant completion, cancellation while waiting, synchronous reservation of owned work, close admission, destination resolution after rebase, native close manifest/media readback, stale-after-install rollback, cancellation rollback, collisions, invalid filenames/size limits, empty stages, live-file protection, retained undo bytes, native save-copy behavior, final-save failure, and early AppKit unblocking.

`ProjectPlanSaveTests` remains unchanged and protects throwing plan/manifest encoding and preservation of the last successful package. The direct-write manifest-load regression now uses coordinated native saves and independent off-main readback.

Frozen `build-6` passed `swift build` with unchanged inventory. It includes registry/accessibility, thumbnail ownership, package-path classification, and undo rebasing, but excludes the newer coordinated-close and queued-generation corrections. Earlier builds failed generation captures, an omitted retry caller, thumbnail cancellation isolation, and SwiftUI localization typechecking; all diagnostics are retained.

Focused gates 1–4 failed during compilation: throwing assertions, an MCP tuple/result mismatch, and two nested `#require` fixture expansions. Those errors are corrected. Gate 5 ran 128 tests in 20 suites with 11 issues; gate 6 ran 137 tests in 21 suites with nine issues. Confirmed close/MCP refusal, thumbnail lifecycle, undo source rebasing, Save As, and generation download cases passed, but stale registry assertions and import undo still failed. Gate 5 also reproduced a reservation race; exclusive rename fixed it and its gate-6 tests passed.

Scoped `import-reservation-2` passed 12 tests in four suites with unchanged frozen hashes. Path imports reuse Finder import; byte imports register shared library-snapshot undo. MCP discovery, import, undo, independent library/disk readback, native redo, retained source bytes, metadata, repeated-import no-op, source-path boundaries, Save As undo, and exclusive reservation/install cases passed. The preceding scoped run failed only because the test requested nonexistent MCP `redo`; corrected proof uses native shared history followed by MCP readback.

Frozen focused gate 7 passed 140 tests in 21 suites with unchanged hashes. It includes registry directory-hint identity regressions and stale-list MCP refusal, package/save/close/thumbnail ownership, generation downloads, import undo, source-path boundaries, and Save As undo rebasing. It excludes the active generation metadata-finalization overlay and narration-intent integration.

Frozen `build-7` passed `swift build`. Its `full-1` ran 2,452 tests in 360 suites with 32 issues. Installer full-URL comparisons falsely rejected a same-path directory-hint change; two guards now compare standardized paths. `media-target-1` passed the new regression and all composition cases, but ran 39 tests with five remaining speech/drone/capture fixture issues. Standalone extraction, clipboard, subtitle, and corrupt-import fixtures also need isolated destination packages; corrections are in progress. The unchanged custom-model routing test retained its previously observed select-after-wait failure. Full integration remains unverified.

Frozen `tsan-1` passed 137 tests in 19 suites with unchanged hashes and no Thread Sanitizer race diagnostics. Command: `swift test --sanitize thread --filter 'ProjectPackage|ProjectRegistry|ProjectAccessibility|ProjectClose|ProjectThumbnailFrameRenderer|VideoProject|ProjectDocumentIO|GenerationDownloadLifecycle|GenerationLifecycle'`. This includes the installer path-identity correction, but excludes pending generation finalization, narration integration, and whole-intent quit admission. No full-suite, final combined MCP, native UI, or complete lifecycle pass is claimed.

Frozen `finalization-4` passed 90 tests in 13 suites with unchanged hashes, including immutable metadata/identity preparation, stale and cancellation matrices, generation terminal ownership, queued downloads, saved media fixtures, real-media readback, and MCP capture/import/undo. The preceding finalization gates 1–3 failed compilation, not runtime. Broader integrated/full/BundledSpeech/final sanitizer gates remain pending; narration and whole-intent admission are excluded.

Frozen `integrated-8` passed 230 tests in 32 suites and `build-8` passed `swift build`. Frozen `full-2` ran 2,466 tests in 361 suites with one issue: unchanged `aRemoteCustomModelWithAStoredKeyIsSelectable` failed its route assertion after waiting before selecting the custom model. All affected package/finalization/fixture suites passed within that failed full run; no full-suite pass is claimed. Unrelated live custom-model/credential edits remain excluded. Every gate preserved its recorded source hashes.

Frozen `tsan-2` passed 160 tests in 22 suites with unchanged hashes and no Thread Sanitizer race diagnostics. It adds finalization/identity stale and cancellation coverage to the package/registry/accessibility/close/thumbnail/document/download baseline. Frozen `bundled-8` passed `swift build --traits BundledSpeech` with unchanged hashes. Narration and whole-intent admission remain excluded. Localization and selective commit are pending; no native UI or complete quit pass is claimed.

Isolated `zsh scripts/localization/sync.sh` completed successfully and generated six English keys for generation admission/cancellation/monitoring. Checker passed 1,412 source strings and reported 8,883 coverage/unknown-key warnings across existing non-English catalogs. Those catalogs are unchanged; this is not complete translation coverage. Post-sync frozen `build-9` passed `swift build`; `resources-9` passed 238 tests in 34 suites, including localization and the affected package/MCP suites. Both preserved hashes. Whole-intent/narration/production/release and native UI remain unfinished.

Linker warnings report bundled `libconvexmobile.a` objects targeting macOS 26.2 against the app's 26.0 minimum. Current-host passes do not establish minimum-OS compatibility; release verification must resolve this before claiming macOS 26.0 support.

After integration and snapshot freeze, run:

```sh
swift build
swift build --traits BundledSpeech
swift test --filter 'ProjectPackageCoordinatorTests|ProjectPackageInstallTests|ProjectClosePersistenceTests|VideoProjectWriteUnblockTests|ProjectDocumentIOTests|VideoProjectLoadTests|ProjectPlanSaveTests'
swift test
```

## Manual verification

Use a disposable project and test media, never a working project.

1. Start a local extraction, frame capture, matte/cutout/composition, and URL download. Save while each is active. Reopen and verify both installed bytes and matching manifest records; no stage files should remain.
2. Save As during an admitted operation, then during an operation queued behind a save. Verify the first result is copied with the save and the queued result installs only in the new package. Test failed Save As and an existing destination.
3. Delete a source or pending asset while processing. Verify no deleted record is resurrected and unpublished output is removed. Undo a successful import or library deletion, then redo; retained backing bytes must remain usable.
4. Close during import, render, and generation download. Verify new operations are refused and final saved state includes every granted successful result. Cancel native close approval and verify admission reopens. Repeat with a final-save failure, then retry.
5. Quit with two projects processing. Verify both gate immediately, neither accepts late commits, and termination waits for final saves. Exercise creation failure, app deactivation, Escape, and repeated close requests.
6. Through an isolated MCP server/project, discover tool schemas, invoke bytes/path/URL import and speech/drone generation, read library and timeline state independently, save/reopen, and undo. Include malformed arguments, removed destinations/sources, cancellation, and asynchronous failure. Success responses alone are not verification.

UI and MCP scenarios above are plans, not passed checks. Profile a representative large-package Save As and close with Instruments before making responsiveness claims.
