# Local finishing

Compositor Pro now carries a finished-video request through assembly, audio finishing, encoded review, repair, and export completion using the existing agent loop. The user supplies the agent model and credentials. Media processing runs on the Mac.

## Behavior

- Default direction favors a focused 30–60-second edit, footage-backed shot choices, clear opening and ending, restrained transitions, consistent typography, and finished dialogue.
- `match_loudness` and `enhance_voice` await required analysis before applying one atomic, undoable edit. Cancellation, unavailable or unmeasurable sources, source replacement, timeline changes, and project closing prevent a late commit. Repeated matching reports `noOp`; gain limits produce explicit warnings.
- Preview, encoded review, and export share prepared audio. Positive gain survives AVFoundation's normalized volume ramps through an audio processing tap. Breath and sibilance regions map from source seconds through trim and speed into timeline frames.
- Plan readiness uses the same placement preflight as assembly. Invalid source durations cannot change plan status or create an undo step. Assembly preserves the planned canvas.
- `review_timeline` renders up to 60 seconds to a temporary MP4 and returns six encoded stills, integrated loudness, sample peak, and clipped-sample count. The caller owns the temporary review file.
- `manage_exports(action="wait", jobId=...)` awaits completion, failure, or cancellation. Canceling the wait leaves the export running.

Source loudness targets are not final-mix guarantees. Clip volume, automation, enhancement strength, playback speed, and overlapping tracks affect output. Rendered stills and meters do not certify motion, intelligibility, true peak, or artistic quality.

Bundled denoise and full voice enhancement require the optional `BundledSpeech` configuration. Local loudness matching, de-breath, Apple transcription, and system/Piper speech do not depend on a bundled local LLM. This change does not add persisted production-run recovery across application restarts.

## Automated verification

Run from the repository root:

```sh
swift build
swift build --traits BundledSpeech
swift test
swift test --filter 'AudioFinishingMutationTests|AudioFinishingRenderTests|LocalFinishingMCPTests|PlanEditToolTests|ExportQueueTests|AudioMixRampTests|CompositionBuildVisualInstructionTests'
swift test --sanitize thread --filter 'AudioFinishingMutationTests|AudioFinishingRenderTests|ExportQueueTests|TextClipPlaybackTests'
git diff --check
```

Verification on 2026-11-06:

- Standard and `BundledSpeech` Swift builds passed.
- Full suite: 2,132 tests across 321 suites passed.
- Focused finishing suite: 26 tests across seven suites passed, including parameterized cancellation, source replacement, close, and export-wait cases.
- Isolated MCP client/server test passed discovery, invalid arguments, atomic validation failure, no-op receipts, gain-limit warnings, encoded review, export waiting, independent output measurement near −16 LUFS, and exact single-step undo restoration. Tests used generated media in temporary directories.
- Thread Sanitizer: 13 tests across four suites passed with no reported races.
- `scripts/dev.sh --no-stream` rebuilt and launched the standard app. Its process was present, and `codesign --verify --deep --strict --verbose=2 .build/CompositorPro.app` passed. Playback and UI behavior await human confirmation.
- `scripts/localization/sync.sh` completed with missing-translation warnings in non-English catalogs. `git diff --check` passed.

Optional speech-enabled packaging previously failed while compiling the dependency's MLX `fp_quantized.metal` kernels. A successful Swift trait build does not establish a working speech-enabled app bundle.

## Manual playback and UI check

UI behavior requires human confirmation; automated tests do not replace this check.

1. Launch `scripts/dev.sh --no-stream`. Create an isolated project with quiet dialogue, several B-roll clips, and an optional music bed. Configure the chosen agent model and API key.
2. Request: “Make a 45-second film from this footage. Preserve the speaker's meaning, use readable captions, finish the audio, review it, and export it. Keep media processing local.” Expect a completed-file path rather than a queued receipt or a request to continue.
3. Listen through preview and the exported file. Check audible gain, dialogue clarity, trims and speed changes, nested audio, caption readability, transitions, and the ending. Move between timeline tabs and change text styling; prepared audio and current text styling should remain correct.
4. Use Match Loudness twice. Expect one effective edit, then a no-op. Undo once should restore the original effects and volume state. Interleave a separate text edit and verify undo boundaries remain distinct.
5. Start finishing, then change the source/trim or close the project. Expect cancellation or a stale-source failure, with no late edit. Switch away from the audio inspector during its operation and verify cancellation leaves no partial effect. Check keyboard focus, Escape, disabled controls, empty selection, and unavailable enhancement states.
6. Export once successfully, then exercise an invalid destination and cancellation. Expect accurate terminal status. Cancel an export wait independently and verify the job can still finish.

No model-driven brief-to-export creative benchmark or head-to-head HyperFrames comparison has been completed.
