# Project document background work

`VideoProject` owns thumbnail and media-restore task handles. Both operations enter through `ProjectPackageCoordinator.startMutation`; coordinator idle includes their terminal cleanup. Background work never writes into a live project package. Thumbnail bytes enter the normal save snapshot.

## Thumbnail cache

One cached result and one active render are retained per document. The request identifies document and project URLs, active timeline, frame rate, maximum image size, ordered eligible clips, trim positions, manifest sources, input identities, asset object identities and URLs, and generation state. A different request invalidates cached bytes immediately and cancels obsolete work.

Every capture schedules an off-main file-stamp check. Unchanged requests and file stamps reuse JPEG bytes without decoding. File replacement at an unchanged URL therefore cannot leave the cache stale indefinitely. A capture can return the previous bytes while this best-effort check runs; changed bytes request another normal checkpoint. Files changed during rendering, cancelled work, closing documents, and obsolete requests cannot publish bytes or request a checkpoint. A stale request finishes before its replacement starts.

Thumbnail image loading, encoding, and file metadata queries run in explicit `@concurrent` operations. The video branch awaits `ProjectThumbnailFrameRenderer`, whose actor owns AVFoundation setup, control, and callback completion off-main. Candidates are attempted sequentially.

### Single-frame cancellation

`ProjectThumbnailFrameRenderer` is a one-shot actor. Its initializer stores only immutable request values and operations; it creates no framework objects. The actor loads video tracks asynchronously, configures one generator, and submits one native single-frame callback request. It owns the generator and continuation until the terminal callback. Overlapping or repeated renders refuse without cancelling the admitted request.

Task cancellation captures only the Sendable actor and hops to it. The actor cancels asset loading and native image generation; it does not resume an active frame continuation early. The callback captures an immutable, retained image/error result and explicitly hops back to the actor. Terminal completion releases framework objects and resumes the continuation once. Cancelled requests return cancellation even if the terminal callback supplies an image. Duplicate and stale callbacks are ignored.

The installed macOS 27.2 SDK `AVAssetImageGenerator.h` documents exactly one callback for `generateCGImageAsynchronously(for:completionHandler:)`, including failed or cancelled generation; cancellation returns `AVErrorOperationCancelled`. Its `cancelAllCGImageGeneration()` contract also requires cancellation callbacks for pending requests. See [AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator). No unchecked conformance, synchronization wrapper, or diagnostic suppression is used.

Before-start cancellation submits no frame request. Cancellation during track loading waits for that asynchronous load to terminate. Once generation starts, coordinator idle waits for the framework terminal callback. There is deliberately no timeout or early teardown: a framework callback that never arrives would keep the admitted operation pending rather than falsely report drained work.

## Media restore

Manifest shells are appended once, preserving existing asset objects and deduplicating IDs. File availability scans operate on immutable URL snapshots off-main. Superseding restores cancel and wait for prior work before scanning or hydrating. Scan results merge only still-current IDs into the current missing-media set; they never replace unrelated concurrent state. Recovery status normalization applies only to reconstructed assets whose initial state remains unchanged; pending initial snapshots survive a superseded scan and are discarded after processing or removal.

Only assets referenced by a current timeline receive metadata hydration. Hydration is sequential and uses temporary assets through the existing `MediaAsset.loadMetadata` operation. Results remain staged until hydration completes. Before loading and after each await, restore validates its revision, both project URLs, asset object and source URL, manifest entry, asset snapshot, pending download URL, generation state, and current timeline use. Removed or replaced assets are never reinserted. Accepted metadata updates are batched through the shared editor operation. Unused media retains manifest metadata until a consumer requests loading.

The integrated shared metadata loader uses immutable `MediaAssetMetadata.Request` values and explicit off-main audiovisual/image preparation, with current-context validation before publication. Lottie inspection still performs main-actor work and remains a separate unfinished renderer change. `prepareMediaVisuals` retains its existing cache-owned worker behavior; this change does not claim to drain those workers.

## Close integration

At the beginning of the upper document close path, call `cancelDocumentBackgroundWork()` immediately after `coordinator.beginClosing()`, before waiting on `ProjectPackageCoordinator.waitUntilIdle()`. Coordinator closing rejects new work and document guards reject late results. Cancellation is cooperative: idle waits until admitted scans and hydration actually return. The upper `onReopen` callback must call `restoreAssetsFromManifest()` when closing is cancelled, so interrupted timeline hydration restarts. Future captures restart optional thumbnail work.

## Verification

`VideoProjectBackgroundWorkTests` covers thumbnail request invalidation, same-URL file changes, files changed during rendering, stale-request replacement, closing and draining, restore source and generation changes, removed and replaced assets, concurrent missing references, duplicate IDs, sequential hydration, lazy unused media, and cancelled metadata commits. `ProjectThumbnailFrameRendererTests` adds off-main preparation/control, zero and invalid requests, before-start and preparing cancellation, terminal-callback drain, success racing cancellation, duplicate/stale callbacks, overlapping refusal, native frame rendering, and invalid native media. Lifecycle tests use injected actor-isolated operations, deterministic signals, and `withPackageTestFixture`; no timing sleeps or external services. The native video fixture uses its existing writer-readiness polling.

The suffix worker parses owned source/tests and compiles the actual frame helper plus the extracted thumbnail caller to object code with Swift 6 complete strict concurrency and warnings treated as errors. The full frame-test source also compiles to object code with the installed Swift Testing macro plugin and a compilation-only document/fixture seam; this is not execution of the repository test suite.

An isolated executable using the actual frame helper, coordinator, test probe/signals, and the existing video fixture passed off-main setup/control, before-start/preparing/generating cancellation, terminal-callback drain, success after cancellation, duplicate/stale callbacks, overlapping/repeated refusal, invalid times/sizes, native zero-time rendering, and missing/corrupt media. Cancellation paths used deterministic injected operations, not native decoder cancellation timing. The temporary executable and media were removed after execution. Load regressions now expect lazy unused-asset metadata.

Integrated frozen `build-8` and `bundled-8` passed normal/BundledSpeech builds. `integrated-8` passed 230 tests in 32 suites; `tsan-2` passed 160 tests in 22 suites without race diagnostics, including document background work and native frame rendering. Hashes remained unchanged. `full-2` ran 2,466 tests with one unchanged custom-model route issue; no full-suite or UI pass is claimed. Whole-intent/transport/visual-cache draining and Lottie remain outside this proof.

Manual verification: open a project containing used and unused video and image assets; confirm timeline visuals appear and unused media hydrates when displayed. Trim the thumbnail candidate, switch timelines, relink media, and save; confirm the project thumbnail updates. Close during restore or thumbnail creation, then cancel close and retry. Confirm no late checkpoint, duplicate assets, stale missing-media badge, or overwritten generation state. UI verification remains pending until a user performs these checks.
