# Caption edit lifecycle

Native caption and transcript generation use `CaptionGenerationController`. It reserves a project intent synchronously before scheduling, including cloud-cost preflight, and owns the task through terminal publication. Duplicate starts refuse while the previous task drains. Dismissal, Escape, and timeline switching cancel the request; canceled requests cannot publish notes, change preview state, or invoke the success callback. Successful completion clears busy state before invoking a callback that may dismiss the view.

Direct generation, transcript preparation, and subtitle import use the same `ProjectPackageCoordinator.withIntent` boundary. Valid same-project tool/native admission nests rather than attempting fresh admission during close. Existing work may finish while closing; fresh requests refuse. Ordinary saves still wait for package mutations, not whole intents, avoiding self-deadlock. Close waits for admitted work and owned tasks before its final save.

Generation snapshots timeline value, project identity, selected source object/preparation revision, resolved availability, duration, and audio eligibility. Relink-away-and-back cannot restore the observed revision. Validation occurs after preparation and again inside the synchronous placement operation, including an asynchronous caller's delayed mutation wrapper. Failed, canceled, and stale operations add no caption track or undo action. Agent transforms remain inside the existing shared undo transaction and outer tool intent.

`CaptionTranscriptionService` supplies an immutable per-source request seam. Its live implementation uses the existing local/cloud transcription and cache paths unchanged; tests inject deterministic results without credentials, real speech models, or shared transcript-cache writes. This slice does not change recognition quality, provider billing/retry, partial-transcription policy, or analysis concurrency.

## Automated evidence

The first regression gate failed to compile because its fixture omitted a required `start` argument; no behavioral evidence came from that attempt. Corrected `swift test --disable-automatic-resolution --jobs 2 --filter CaptionGenerationLifecycleTests` ran three tests and failed six assertions against the original lifecycle implementation: false close idleness, wrong fresh-request refusal, and stale caption placement/undo after restoring a source URL. The transcription dependency seam was present in that before run; lifecycle behavior was unchanged.

After both review fixes (editor-owned controller across tab switches; manifest-derived URL snapshots with off-main availability checks instead of main-thread `fileExists`), final gates passed: `swift build` and `swift build --traits BundledSpeech` clean; focused `swift test` passed 29 tests in 6 suites (including tab-switch drain, cancellation, ABA restore, suspended-mutation revalidation, and MCP readback/persistence/undo); TSan focused passed 60 tests in 8 suites with zero race diagnostics; full `swift test` passed 2,562 tests in 373 suites. These runs execute alongside unrelated dirty work (finishing/credentials) that remains excluded from this commit. An isolated staged-only snapshot (HEAD `f6dbc7e` plus only this slice's patch) was then built and passed the same 29 focused tests and the full suite at 2,540 tests in 369 suites with zero failures, proving the commit bytes standalone. Authored tests alone are not verification.

## Manual native verification

Use a disposable saved project containing spoken audio:

- Generate captions, then close with Command-W or the window button while transcription is active. Expect admitted work to drain before the final save/removal; reopen and verify the last successful captions.
- Press Escape or leave the Captions/Transcribe tab during preparation. Expect no late track, note, preview change, or panel switch. Return while cancellation drains; another generation must not overlap it.
- Double-click Generate. Expect one caption group and one undo action. Successful completion switches panels only once; Undo/Redo restores the exact group and stable clip IDs.
- Change the timeline or relink audio during preparation. Expect refusal rather than captions from stale audio. Restore the old URL; the stale result must still refuse.
- Try an empty selection, silent recording, missing source, disabled controls, and a failed transcription. Verify actionable state and unchanged undo. Exercise keyboard focus and both caption/transcript output modes.
- Cancel close or force a final-save failure in a disposable destination. Expect the document to remain open and fresh generation to work once all close owners release.

Human UI/playback and real recognition remain unverified until the user confirms them. Finder/drop admission, deferred settings-sheet placement, cached-transcript UI callbacks, native gestures/text, exports, HTTP output drain, full quit, signed packaging, and installation remain separate unfinished boundaries.
