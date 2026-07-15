# Audio playback contract — v1 (E4.5)

Normative spec for Stage D's audio-playback / A/V-clock milestone. This is the UI↔engine
contract referenced by the Windows-port plan's "Audio engine & A/V clock" section — the C ABI
additions in `native/include/palmier_engine.h` and the `IVideoEngine` additions in
`PalmierPro.Services.Engine` are the two normative surfaces this document specifies. **This
document defines the contract only** — no native `.cpp`/`.h` implementation, no
`TimelineSnapshotBuilder.cs` changes, no `NativeMethods.cs`/`TimelineSession.cs` P/Invoke wiring
ship with it (see §9 for exactly which future agent owns each of those). `IVideoEngine`'s new
members are stubbed with `NotSupportedException` in `VideoEngine.cs` today, exactly like every
other not-yet-landed surface this interface already declared in Stage B (`PlayheadChanged`/
`IsPlayingChanged`, declared then, unraised until now).

## 1. Audio model (recap — already ported, not part of this contract's scope)

The gain model is fully specified by existing Swift/C# code; this section only restates it so
the mix loop this contract feeds has an unambiguous formula to implement, with exact citations.

- **Per-clip effective gain**, mirroring `Clip.volumeAt(frame:)` (`Sources/PalmierPro/Models/
  Timeline.swift:269-277`) and its already-ported `Timeline.cs:320-325` (`VolumeAt`):

  ```
  gain(frame) = clip.volume × dbKeyframeGain(frame) × fadeMultiplier(frame)
  dbKeyframeGain(frame) = VolumeScale.linearFromDb(volumeTrack.sample(frame))   // 1.0 if no active track
  ```

  `VolumeScale.linearFromDb`/`dbFromLinear` (`InspectorView.swift:1063-1076`, ported verbatim as
  `PalmierPro.Core.Models.VolumeScale` — see `Timeline.cs:32`) clamp to `[-60, +15]` dB and treat
  `db == floorDb` as hard zero. `fadeMultiplier` (`Timeline.swift:302-317`, `Timeline.cs:342`) is
  the linear/smoothstep head-and-tail ramp driven by `fadeInFrames`/`fadeOutFrames`/
  `fadeIn|OutInterpolation`.
- **`Track.muted`** (audio-type tracks only) zeroes every clip on that track's contribution
  outright — it is not folded into `gain(frame)`, it is a track-level mix-loop skip (§6).
- **No pan.** The Swift model has no pan field anywhere on `Clip`/`Track`, and neither does the
  Windows port. **Do not add one to the mix path** — every audio clip contributes identically to
  both output channels (mono source: duplicate to L/R; stereo source: L/R passed through
  unmodified), full stop.
- **`audio.denoise`** (`Clip.denoiseEffectType`, `Timeline.swift:288`) is the only registered
  audio `Effect` type. Phase 3 renders it (wet/dry blend); Phase 1 decodes the effect entry (it
  travels through `SnapshotClip.Effects` like any other effect — `Clip.Effects` is not gated by
  `mediaType`, so an audio-type clip can carry one) and **bypasses** it — the mix loop must
  recognize the type string and skip it without erroring, mirroring the general "an effect chain
  may reference a kind this engine build doesn't implement yet — not an error" convention already
  established for the video effect chain (`docs/timeline-snapshot-v1.md` §11.3).

**Schema gap this contract does NOT close:** `SnapshotClip`'s `volume.gain`/`fadeInFrames`/
`fadeOutFrames`/`fadeIn|OutInterpolation` fields already exist and are already populated
(`TimelineSnapshotBuilder.cs:300-304`) — the mix loop can implement the fade-envelope half of
`gain(frame)` today. The **dB keyframe track** (`volumeTrack`) has no wire representation yet:
`TimelineSnapshotSerializer.WriteClip` hard-codes `w.WriteNull("keyframes")` inside the `volume`
object with the literal comment `// volume dB keyframe track — E4.5 (audio playback), not video
render` (`TimelineSnapshotBuilder.cs:519`). Closing this gap means, additively, exactly mirroring
the existing `opacity`/`crop` v1.1 keyframe-envelope pattern (`docs/timeline-snapshot-v1.md`
§11.2): a `SnapshotClip.VolumeKeyframes` field (`List<SnapshotKeyframe<double>>?`, dB values, same
`BuildKeyframes(clip.VolumeTrack, kf => kf.Value)` call already used for opacity/crop), a
`docs/timeline-snapshot-v1.md` §11 addendum documenting it, and a native
`TimelineSnapshotParser`/`SnapshotClip.h` field to parse it. **Whoever implements the "mix" slice
(§9) makes this schema change** — it is not part of this document's own deliverables (this
contract only specifies that it's needed and exactly what shape it must take, so that
implementation is a mechanical follow of an established pattern, not a design decision).

## 2. Buffer/format decision — float32 stereo interleaved, 48 kHz

**Verified against the Mac.** AVFoundation/`AVPlayer` never exposes an explicit "engine mix
buffer format" (it negotiates with CoreAudio internally) — the closest the Mac has to one is
`ScrubAudioEngine`'s own PCM capture format, which is Float32 stereo 48 kHz non-interleaved
(`Sources/PalmierPro/Preview/ScrubAudioEngine.swift:31-33`: `sampleRate = 48_000.0`,
`channelCount: AVAudioChannelCount = 2`, and its `AVAssetReaderAudioMixOutput` settings at
lines 308-316 request `AVLinearPCMIsFloatKey: true`, 32-bit, non-interleaved). Every other place
the Mac codebase pins an explicit sample rate agrees: `HDRVideoExporter.swift:101-108` (export
AAC settings, `AVSampleRateKey: 48000`, `AVNumberOfChannelsKey: 2`), `FCPXMLExporter.swift:769`
and `XMLExporter.swift:211,325` (`audioRate`/`samplerate` = 48000 in emitted XML). There is no
counter-example anywhere in the Mac codebase using 44.1 kHz for anything timeline/mix-related.
**Windows mix bus: Float32, 48,000 Hz, 2 channels (stereo).**

- **Interleaved vs. planar is a pipeline-position decision, not one format:** per-clip decode
  (via a per-clip `SwrContext`, resampling/channel-mapping straight to the bus format so no
  second resample pass is needed downstream) and the mix accumulator both work in **planar**
  Float32 (matches `ScrubAudioEngine`'s own `left`/`right` separate-array convention, and matches
  `PE_ExtractPeakEnvelope`'s existing mono-planar-style reduction — no format switch needed to
  reuse peak-style code for a future meter tap, see §8). **Interleaving happens exactly once**,
  immediately before `IXAudio2SourceVoice::SubmitSourceBuffer` — XAudio2 source voices are
  configured via a `WAVEFORMATEX`-described interleaved stream; there is no planar submission
  path in XAudio2 (unlike WASAPI's optional planar rendering mode).
- **Mix block size / queue depth are internal, not ABI-visible.** Recommended starting point:
  20 ms blocks (960 frames @ 48 kHz), 4–6 blocks queued ahead (80–120 ms of buffered lead time) —
  small enough to keep seek-to-audible latency low, large enough that a single slow decode
  doesn't starve the voice. This is a tuning constant owned by whichever agent implements the
  mix loop (§9), not part of the ABI surface below.
- **No limiter/clamp in v1.** Multiple simultaneous full-volume clips can sum past ±1.0 and clip
  at the device — this matches the Mac, which has no limiter on its `AVAudioMix` path either.
  Not a gap to close silently; a genuine parity decision.

## 3. Clock semantics

**Design (from the plan, restated precisely):** the engine's own mix loop renders every audible
clip into **one persistent `IXAudio2SourceVoice`** per open timeline (not one voice per clip —
per-clip voices are created/destroyed with each clip's lifetime and so never carry a *continuous*
sample counter across a whole timeline; a single long-lived voice's `SamplesPlayed` is the
continuous counter this whole design rests on). The timeline's master clock reads from that
counter. `SamplesPlayed`, by XAudio2's own definition ("total number of samples processed by this
voice's channel since the last call to `Start` following either voice creation or
`FlushSourceBuffers`"), already excludes samples still sitting in the submitted-but-unplayed
buffer queue — it counts what has actually been played, not what has merely been handed to the
voice. **No separate "minus queued" subtraction is performed by this contract's formula**; that
subtraction is exactly what distinguishes `SamplesPlayed` from "total submitted," and is already
done for the implementer by the API. (Residual device-buffer latency between "XAudio2 considers
this sample played" and "the speaker actually emits it" is on the order of single-digit
milliseconds — well inside the plan's own `±1 frame over 5 min` lip-sync bar at any Phase-1-target
frame rate — and is not compensated for separately.)

### 3.1 Rebase state

Each open timeline (native, owned by its `TimelineSession`) carries:

```
rebaseFrame    : int64   // timeline frame the clock reads AT the moment of rebase
rebaseQpc      : int64   // QueryPerformanceCounter() ticks at the moment of rebase (QPC-fallback path)
rebaseSamples  : uint64  // voice SamplesPlayed observed at the moment of rebase (0 right after Flush+Start)
rate           : double  // 0.0 (paused) or 1.0 (playing) — v1 accepts no other value, see §4
usingAudioClock: bool    // which of {SamplesPlayed, QPC} is authoritative right now
```

A **rebase** — `rebaseFrame`/`rebaseQpc`/`rebaseSamples` all reset together — happens on:
`PE_TimelinePlay`, `PE_TimelinePause`, `PE_TimelineSetRate`, every `PE_TimelineSeek` (regardless
of mode, **including while already playing** — see §3.3), and an **implicit** rebase whenever
`usingAudioClock`'s underlying reason flips (§3.2).

### 3.2 Clock formula

**While playing (`rate == 1.0`) and `usingAudioClock`:**

```
elapsedSamples = voice.SamplesPlayed()        // voice reset to 0 at last rebase's Flush+Start
elapsedSeconds = elapsedSamples / 48000.0
clockFrame     = rebaseFrame + floor(elapsedSeconds × timelineFps)
```

**While playing and NOT `usingAudioClock` (QPC fallback):**

```
elapsedSeconds = (QueryPerformanceCounter() - rebaseQpc) / QPCFrequency
clockFrame     = rebaseFrame + floor(elapsedSeconds × timelineFps)
```

**While paused (`rate == 0.0`):** `clockFrame = rebaseFrame` — a pure, O(1) return with no voice
or QPC query at all; the clock is frozen by definition (this is why `PE_TimelineGetClockFrame`
never blocks on anything, even in this branch).

`PE_TimelineGetClockFrame` implements exactly this formula synchronously; the continuous-playback
present loop (§3.4) calls the *same* internal function, not a duplicate.

### 3.3 Rebase triggers, in full

| Trigger | New `rebaseFrame` | Voice action |
|---|---|---|
| `PE_TimelinePlay` (from paused) | unchanged (current `rebaseFrame`, i.e. wherever the clock was frozen at) | `FlushSourceBuffers`, then `Start` |
| `PE_TimelinePause` | current `GetClockFrame()` result, frozen | `Stop`, then `FlushSourceBuffers` (discard anything still queued — no stale tail plays after resume) |
| `PE_TimelineSeek` (any `PE_SeekMode`, any time — see below) | the seek's target frame | `Stop` + `FlushSourceBuffers` if playing; mix loop resumes submitting from the new frame on the very next block |
| `PE_TimelineSetRate` | current `GetClockFrame()` result | rate 0→1: `FlushSourceBuffers`+`Start` as above; rate 1→0: `Stop`+`FlushSourceBuffers` as above |
| Implicit audible↔silent flip (§3.2's `usingAudioClock`) | the exact frame where the flip occurs | switching TO audible: `FlushSourceBuffers`+`Start` fresh; switching TO silent: `Stop`+`FlushSourceBuffers`, hand off to QPC |

**`PE_TimelineSeek` while `isPlaying` does *not* implicitly pause.** This mirrors the Mac
precisely: `VideoEngine.seek(to:mode:)`'s `.exact`/`.interactiveScrub` branches never call
`pause()`; only `.audibleStepForward`/`.audibleStepBackward` do
(`Sources/PalmierPro/Preview/VideoEngine.swift:94-98`: `if editor.isPlaying { pause() }`, gated to
just those two cases). So: a user dragging the playhead position indicator while the timeline
plays performs a rebase-and-continue, not a rebase-and-freeze. The `AudibleStepForward/Backward`
pause-first behavior is **caller policy** implemented in the future `VideoEngine.Seek` (C#), not
something `PE_TimelineSeek` itself enforces — matches this ABI's existing precedent of keeping
policy (coalescing, tolerance sizing) in `SeekCoordinator`/`VideoEngine.cs` and mechanism in
native (see `VideoEngine.cs`'s own remarks on `SeekCoordinator.InteractiveTolerance` not being
threaded through `PE_TimelineSeek`).

### 3.4 `usingAudioClock` — the no-audio / no-device fallback, and its two distinct triggers

The plan calls for "a no-audio fallback: QPC-based software clock." There are **two separate
reasons** this contract folds into the *same* fallback path:

1. **No audible clip.** At any timeline frame, walk every `"audio"`-type `SnapshotTrack` that
   isn't `muted` and check whether any of its clips' `[startFrame, endFrame)` covers the current
   position. If none do (silence — nothing to submit to the voice), `usingAudioClock = false`.
   This is re-evaluated by the mix loop every time it's about to render the next block (so a
   silent gap between two dialogue clips is detected and handled, not just "no audio in the whole
   project"). A **muted** track's clips do not count as audible for this check even though they
   still fully exist in the snapshot per `docs/timeline-snapshot-v1.md` §3 (so unmuting stays a
   `RefreshParams`-only change with no rebuild) — the mix loop skips decoding them entirely
   (§6), which is both a real optimization and the direct reason they can't keep the audio clock
   alive.
2. **No audio device at all.** `IXAudio2::CreateMasteringVoice`/the source voice creation can fail
   outright — expected on CI runners with no audio endpoint, mirroring exactly the reason
   `EngineSession::EnsureGraphicsDevice` already falls back from `D3D_DRIVER_TYPE_HARDWARE` to
   `D3D_DRIVER_TYPE_WARP` for graphics on GPU-less CI (`palmier_engine.h`'s D3D11 presentation
   section, `EngineSession.h:92-94`). When device/voice creation fails once at
   `TimelineSession` construction (or first `PE_TimelinePlay`), `usingAudioClock` is permanently
   `false` for that session's lifetime — there is no retry loop. **This never surfaces as a
   non-`PE_OK` status from any ABI call in this contract** — `PE_TimelinePlay` on a device-less
   machine still succeeds and plays silently on the QPC clock; this is a requirement, not just a
   convenience, because it's exactly what keeps CI able to exercise Play/Pause/Seek/GetClockFrame
   deterministically without a real audio device (mirroring the existing WARP-forced GPU test
   pattern in CI — see the plan's "GPU-less CI" note).

Both triggers converge on identical clock math (§3.2's QPC branch) — the mix loop doesn't need to
distinguish *why* it's on the fallback, only that it is.

### 3.5 Video presents against the active clock

Once `PE_TimelinePlay` starts continuous playback, the timeline's existing render thread (today
purely seek-reactive — see `TimelineSession.h`'s `RenderThreadLoop`) additionally runs a
present loop:

```
while isPlaying:
    wait up to ~8 ms (not exactly 1/fps — see below)
    frame = GetClockFrame()          // §3.2, same internal call PE_TimelineGetClockFrame exposes
    if frame != lastPresentedFrame:
        ComposeFrame(frame) and present it if a swap chain is attached
        fire PE_PlayheadCallback(frame)      // see §4 — same callback Seek already fires
        lastPresentedFrame = frame
    if timelineDurationFrames > 0 and frame >= timelineDurationFrames:
        internally perform the same work as PE_TimelinePause, THEN fire PE_IsPlayingCallback(false)
        break
```

- **Always presents the *latest* clock frame; never queues a backlog.** If compose+present for
  one iteration takes longer than the wait interval, the next iteration's `GetClockFrame()` has
  already moved further ahead — the skipped frames are dropped, not queued. This is the literal
  meaning of "video presentation schedules/drops frames against the active clock" from the plan.
- **The wait interval is decoupled from the timeline's own fps** (an 8 ms/~120 Hz poll keeps pace
  with high-refresh-rate displays and avoids visibly missing a fast-moving frame boundary at
  60 fps timelines; sleep precision at exactly `1/fps` isn't reliable on Windows regardless). The
  exact constant is an implementation tuning knob for whichever agent builds this loop (§9), not
  part of the ABI.
- **Auto-stop at end-of-timeline** mirrors the Mac's own periodic-time-observer behavior
  (`VideoEngine.swift:483-485`: `if duration > 0, frame >= duration { self.pause() }`) — on the
  Mac this is also engine-internal (driven by `AVPlayer`'s periodic callback), not a UI-side poll,
  so mirroring it as engine-internal here (rather than requiring the C# side to watch
  `PlayheadChanged` and call `Pause` itself) is a direct port of where the behavior already lives,
  not a new design choice.

## 4. ABI additions

Declared in `native/include/palmier_engine.h` (see that file for the literal, doc-commented
declarations — reproduced here for reference; the header is the source of truth if the two ever
drift):

```c
PALMIER_API int32_t PE_TimelineSetRate(PE_TimelineHandle timeline, double rate);
PALMIER_API int32_t PE_TimelinePlay(PE_TimelineHandle timeline);
PALMIER_API int32_t PE_TimelinePause(PE_TimelineHandle timeline);
PALMIER_API int32_t PE_TimelineGetClockFrame(PE_TimelineHandle timeline, int64_t* outFrame);

enum PE_ScrubAudioDirection : int32_t
{
    PE_SCRUB_AUDIO_FORWARD = 0,
    PE_SCRUB_AUDIO_REVERSE = 1,
};
PALMIER_API int32_t PE_TimelineScrubAudio(PE_TimelineHandle timeline, int64_t frame, int32_t direction);

typedef void (*PE_IsPlayingCallback)(void* userCtx, int32_t isPlaying);
PALMIER_API int32_t PE_TimelineSetIsPlayingCallback(PE_TimelineHandle timeline, PE_IsPlayingCallback callback, void* userCtx);
```

**Why `PE_TimelineSetRate` takes a `double`, not a `float`, despite XAudio2/HLSL-adjacent code
elsewhere in this engine favoring `float`:** every existing *scalar value* parameter in
`palmier_engine.h` (`timelineSeconds`, `startSeconds`, `durationSeconds`, `peaksPerSecond`) is
`double` — `float` in the existing ABI is reserved for bulk sample/pixel buffers
(`PE_ExtractPeakEnvelope`'s `outBuffer`), never a scalar. `rate` follows the established scalar
convention.

**Why `PE_TimelinePlay`/`PE_TimelinePause` exist as their own entry points rather than requiring
every caller to spell out `PE_TimelineSetRate(timeline, 1.0)`/`(timeline, 0.0)`:** they are also
where the plan's naming (`IVideoEngine.Play`/`Pause`, mirroring the Mac's `VideoEngine.play()`/
`pause()` 1:1) lands on the C# side — see §7. `PE_TimelineSetRate` remains the general primitive
underneath both (`PE_TimelinePlay(t)` ≡ `PE_TimelineSetRate(t, 1.0)`), kept separate because the
plan's own clock-design language ("rate changes re-anchor the clock") describes a general
mechanism the ABI should expose even though Phase 1 only ever drives it to 0.0 or 1.0 — a future
shuttle/J-K-L feature is then a *value* change, not an ABI break, matching this codebase's
existing "reserve the shape now" discipline (see `docs/timeline-snapshot-v1.md` §5 on the
opacity/crop keyframe envelope reserved ahead of E3).

**Why `PE_TimelineSetRate` rejects everything except `{0.0, 1.0}` in v1:** Phase 1's milestone
table has no shuttle/variable-speed-preview feature anywhere (only per-clip `speed`, an entirely
separate, already-shipped mechanism — §1 doesn't touch it, retiming is `TimelineSnapshotBuilder`/
`GpuCompositor` territory, not the playback clock). Accepting an unimplemented value silently
(clamping, or worse, silently no-op-ing) would be a worse failure mode than a loud
`PE_ERROR_INVALID_ARGUMENT` — callers should never be able to "successfully" request a rate this
build cannot honor.

**`PE_PlayheadCallback` (already existed since E2) is being broadened, not replaced.** Its
existing doc comment says it fires "each time [the render thread] actually composes... a frame in
response to `PE_TimelineSeek`." As of this contract it *also* fires once per frame actually
presented by the §3.5 continuous-playback loop — same callback, same threading contract (may run
on a background thread; marshal to the UI thread in the subscriber), no signature change. The
header comment is updated accordingly (§4's code block above doesn't re-declare it — no signature
change means no new line needed there — see the actual header diff for the updated prose).

**`PE_TimelineSeek`'s existing doc comment gains one clause:** calling it while `isPlaying` is
true performs a rebase and playback continues (§3.3) — it does not implicitly pause. This was
already implicitly true (nothing about the existing seek-mailbox design required pausing), this
contract just makes it explicit now that "isPlaying" is a real, tracked state.

## 5. Scrub audio (`PE_TimelineScrubAudio`)

Mirrors `ScrubAudioEngine.scrub`/`makeGrain`/`edgeGain`
(`Sources/PalmierPro/Preview/ScrubAudioEngine.swift:72-99,232-253,286-289`): a short (~50 ms —
matches the Mac's `grainFrameCount = 2_400` samples at 48 kHz), edge-faded (matches
`fadeFrameCount = 144` samples ≈ 3 ms linear ramp at both ends, avoiding clicks) window of audio
around `frame`, played through a **lightweight voice separate from the persistent playback
voice** — mirrors the Mac's own separation between `AVPlayer` (main playback) and
`ScrubAudioOutput`/`ScrubAudioEngine` (an entirely independent output path). Uses the *same*
per-clip gain formula and `Track.muted` handling as §1/§6 — a scrub grain is a miniature,
one-shot instance of the same mix, not a different code path for gain.

- **Retimed-clip scrub audio is pitch-shifting — a sanctioned v1 parity exception.** For a clip
  with `speed != 1.0` the grain maps timeline→source at the retimed rate and plain
  linear-interpolates the window, so a 2×-speed clip scrubs an octave up and a 0.25× clip two
  octaves down. This diverges from the pitch-preserving *playback* mix (§6 step 2's stretcher) and
  from the Mac, whose `ScrubAudioEngine` reads pre-composited timeline audio AVFoundation has
  already retimed pitch-preserved. It is deliberate: the WSOLA/STFT stretcher's priming latency
  (~60 ms) exceeds the 50 ms grain, so routing a one-shot grain through it is impractical, and a
  momentary scrub-feedback transient tolerates the shift where sustained playback would not. Native
  performs no attenuation for extreme speeds; the grain plays pitch-shifted at full gain.

**Despite the name mirroring only `audibleStep*`, this call serves BOTH scrub UI cases.** On the
Mac, `ScrubAudioEngine.scrub` is invoked from *both* `.interactiveScrub` (continuous drag —
`VideoEngine.swift:92`, unconditionally on every scrub-mode seek) and
`.audibleStepForward`/`.audibleStepBackward` (`VideoEngine.swift:96`) — never from `.exact`
(`.exact` calls `scrubAudioEngine.stopScrubbing()` instead, `VideoEngine.swift:88`). The future
`VideoEngine.Seek` (C#) should call `PE_TimelineScrubAudio` whenever `mode != PreviewSeekMode.Exact`,
not only for the two `AudibleStep*` cases — the task naming is about the discrete-step *button*
use case being the primary motivating one, not an exhaustive restriction.

- **`direction` is always caller-supplied; native performs no auto-detection.** The Mac derives
  direction from comparing the requested sample to the previous one
  (`ScrubAudioEngine.swift:79-88`) — that bookkeeping is *policy*, kept on the C# side (a single
  "last scrubbed frame" field on the future `VideoEngine`), matching this ABI's existing
  precedent of keeping policy in C# and mechanism in native (see `VideoEngine.cs`'s remarks on
  `SeekCoordinator.InteractiveTolerance` not being threaded through `PE_TimelineSeek` either).
- **Latest-wins.** A new `PE_TimelineScrubAudio` call cuts off any still-playing grain from a
  previous call and starts immediately — matches the Mac's `latestRequest` replacement semantics.
- **Caller discipline, not an ABI-enforced invariant:** callers are expected to `PE_TimelinePause`
  before scrubbing, mirroring the Mac's `if editor.isPlaying { pause() }` guard
  (`VideoEngine.swift:95`) for the `AudibleStep*` modes specifically (interactive-scrub dragging
  is only reachable from UI states where playback is already stopped). Calling
  `PE_TimelineScrubAudio` while the persistent playback voice is also active is not a documented
  error — the two voices will audibly fight for the same output device — but this contract does
  not require native to detect or reject that; it's the same class of caller-enforced contract
  already used for the swap-chain UI-thread requirement.
- **Never fails on content grounds.** No audible clip at `frame`, or a transient decode failure,
  produces a silent grain and still returns `PE_OK` — a persistently failing source surfaces
  through the existing `PE_TimelineGetUnprocessableMediaRefsJson` channel, exactly like a failing
  video decode already does, not through this call's return code.

## 6. Mix-loop wiring checklist (for §9's "mix" agent — not this document's own deliverable)

Per timeline, per mix block, for every non-`muted` `"audio"`-type `SnapshotTrack`, for every clip
covering the block's frame range:

1. Skip entirely (no decode) if the clip's track is `muted`, or the clip is outside
   `[startFrame, endFrame)` for this block.
2. Decode the covered sample range via a per-clip `SwrContext` straight to Float32/48 kHz/stereo
   planar (§2) — respecting `clip.speed`/`trimStartFrame` exactly like the video path's
   timeline-frame→source-frame mapping (`trimStart + (frame − startFrame) × speed`, per the
   plan's "Retiming is first-class" render-graph section), and running the retimed sample stream
   through the WSOLA-style pitch-preserving stretcher when `speed != 1.0` (§9's "retime" slice —
   NOT `atempo`, which is export-only per the plan).
3. Compute `gain(frame)` per §1 and scale the decoded block.
4. Sum into the shared block accumulator (no limiter — §2).
5. Recognize (and skip, never error on) an `"audio.denoise"` entry in `clip.effects` — §1.
6. After every contributing track/clip is folded in for this block, interleave once and
   `SubmitSourceBuffer` to the persistent voice (§2/§3).

## 7. `IVideoEngine` additions (C#)

Declared in `IVideoEngine.cs`, stubbed with `NotSupportedException` in `VideoEngine.cs` — see
those files for the literal code; summarized here:

| Member | Kind | Notes |
|---|---|---|
| `void Play(string timelineId)` | method | → `PE_TimelinePlay`. Mirrors `VideoEngine.play()` naming. |
| `void Pause(string timelineId)` | method | → `PE_TimelinePause`. Mirrors `VideoEngine.pause()`. |
| `void SetRate(string timelineId, double rate)` | method | → `PE_TimelineSetRate`. v1 real implementation should itself reject rate ∉ {0.0, 1.0} client-side too (fail fast, don't rely solely on the native `PE_ERROR_INVALID_ARGUMENT` round-trip). |
| `bool IsPlaying(string timelineId)` | method | Synchronous query. **Not** backed by a new native poll call — the real implementation tracks last-known state locally (set by `Play`/`Pause`/`SetRate` and by the `IsPlayingChanged` callback, including the engine's own auto-stop-at-end), defaulting to `false` for a timeline that was opened but never played. |
| `event EventHandler<PlayheadChangedEventArgs>? PlayheadChanged` | event | **Already existed** (Stage B) — this contract is what finally gives it a firing source during playback, not seek alone (§3.5, §4). No signature change. |
| `event EventHandler<bool>? IsPlayingChanged` | event | **Already existed** (Stage B) — wiring point for `PE_TimelineSetIsPlayingCallback`. No signature change. |

No new `IVideoEngine` member for `PE_TimelineScrubAudio` — the existing `Seek(string timelineId,
int frame, PreviewSeekMode mode)` already carries everything `PE_TimelineScrubAudio` needs
(frame + mode); the real `VideoEngine.Seek` implementation calls both `PE_TimelineSeek` and (per
§5) `PE_TimelineScrubAudio` internally when `mode != Exact`. This is a single-method contract on
the C# side even though it fans out to two native calls — matches how `Seek` already single-
handedly represents both the video-seek and (once landed) audio-scrub halves of one user gesture.

## 8. Deferred: AudioMeter tap

The plan's Audio-engine section also names "AudioMeter tap feeding the ported `AudioMeterView`
(Stage E)." That UI lands with Stage E's M5, not Stage D's E4.5, and is **not** part of this
contract. Flagged here only so the mix-loop implementer (§9) leaves an obvious seam: the
per-block planar accumulator (§2, §6) is already in the exact shape `AudioLevelAnalyzer.analyze`
(`Sources/PalmierPro/Audio/AudioMeter.swift:86-96`) consumes on the Mac (left/right planar Float32
+ a range) — a future meter-tap callback can be added as a pure additive ABI function
(`PE_TimelineSetMeterCallback`, firing per mix block with peak-per-channel) without touching
anything specified in this document, exactly the same way `PE_ExtractPeakEnvelope`'s peak
reduction already doesn't need to know about playback at all.

## 9. Agent split — who implements what

This contract intentionally separates concerns so the following can proceed in parallel once this
document and the ABI header land:

| Slice | Owns | Key files |
|---|---|---|
| **infra** | XAudio2 device/mastering-voice lifecycle, the persistent per-timeline source voice (create/`Start`/`Stop`/`FlushSourceBuffers`), `IXAudio2VoiceCallback` buffer-refill plumbing, `PE_TimelinePlay`/`Pause`/`SetRate`/`GetClockFrame` ABI implementations, wiring `TimelineSession`'s render thread into continuous-playback mode (§3.5) alongside its existing seek-reactive mailbox mode, the CI/no-device fallback path (§3.4 trigger 2) | new `native/AudioEngine.h/.cpp` (device+voice), `native/TimelineSession.h/.cpp` (present-loop integration), `NativeMethods.cs`, `TimelineSession.cs` |
| **mix** | The per-block mix loop itself (§6): per-clip audio decode via `SwrContext`, gain application (§1), `Track.muted` skip, summing, interleave-and-submit; the `SnapshotClip.VolumeKeyframes` schema addition (§1's "schema gap") in `TimelineSnapshotBuilder.cs`/`TimelineSnapshotSerializer` + a `docs/timeline-snapshot-v1.md` §11 addendum + native parser support | `native/AudioMixer.h/.cpp`, `MediaSource.h/.cpp` (new PCM-decode entry point), `TimelineSnapshotBuilder.cs`, `docs/timeline-snapshot-v1.md` |
| **clock** | The rebase-state struct and clock-formula implementation (§3.1–§3.4) as a small, independently unit-testable component (no XAudio2/D3D11 dependency — pure math over `{rebaseFrame, rebaseQpc, rebaseSamples, rate, usingAudioClock}` plus injected `SamplesPlayed`/QPC readers, so it's testable without a real audio device, mirroring `SeekCoordinator`'s own "inject a synchronous scheduler" testability pattern) | new `native/AVClock.h/.cpp`, consumed by both infra (present loop) and `PE_TimelineGetClockFrame` |
| **scrub** | `PE_TimelineScrubAudio` (§5): grain windowing/fade, the separate lightweight scrub voice, latest-wins cutoff; the future `VideoEngine.Seek` (C#) wiring that calls it alongside `PE_TimelineSeek` | `native/ScrubAudio.h/.cpp`, `VideoEngine.cs` |
| **retime** | Realtime pitch-preserving stretch (signalsmith-stretch or SoundTouch, per the plan) integrated into the mix loop's per-clip decode step (§6 step 2) when `clip.speed != 1.0` — preview path only; export's `atempo` chain is separate, already-scoped, out of this contract | new `native/PitchStretch.h/.cpp`, called from `native/AudioMixer.cpp` |

**Dependency ordering:** clock has no dependency on the others (pure math, lands first/in
parallel). infra depends on clock (present loop needs `GetClockFrame`) but not on mix (infra can
submit silence buffers and still exercise Play/Pause/Seek/rebase correctness end-to-end before
mix exists). mix depends on infra (needs a voice to submit to) and on retime for the `speed != 1`
case specifically (can land mix for `speed == 1` first, retime as a follow-up that only touches
step 2 of §6's checklist). scrub depends on clock (needs `Track.muted`/gain from §1, shares §6's
gain logic with mix, but its own voice lifecycle is independent of infra's persistent voice) and
can proceed in parallel with mix once §1/§6's gain formula is agreed (it already is, by this
document).
