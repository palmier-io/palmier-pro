#pragma once

#include <cstdint>

// Flat C ABI for PalmierEngine.dll. Consumed via P/Invoke from PalmierPro.Rendering
// (src/PalmierPro.Rendering/NativeMethods.cs). Every entry point added from Stage A
// onward takes an explicit engine-session handle.
//
// Handles are opaque; callers must not dereference them. All status codes are
// int32_t: 0 = PE_OK, negative = error (see PE_Status). Buffers returned via
// out-params (PE_FrameBuffer, PE_GetLastErrorMessage) are owned by the engine and
// are only valid until the next call that could invalidate them (documented per
// entry point) — copy out anything the caller needs to retain.
//
// Stage A (E1) is CPU-only software decode; the session/media split exists so a
// D3D11VA hardware path can slot in behind PE_DecodeFrameAt/PE_ExtractThumbnails
// without an ABI break.

#ifdef PALMIERENGINE_EXPORTS
#define PALMIER_API extern "C" __declspec(dllexport)
#else
#define PALMIER_API extern "C" __declspec(dllimport)
#endif

typedef struct PE_Session* PE_SessionHandle;
typedef struct PE_Media* PE_MediaHandle;
typedef struct PE_Timeline* PE_TimelineHandle;
typedef struct PE_AlphaEncoder* PE_AlphaEncoderHandle;

enum PE_Status : int32_t
{
    PE_OK = 0,
    PE_ERROR_UNKNOWN = -1,
    PE_ERROR_INVALID_ARGUMENT = -2,
    PE_ERROR_INVALID_HANDLE = -3,
    PE_ERROR_FILE_OPEN_FAILED = -4,
    PE_ERROR_NO_STREAM = -5,
    PE_ERROR_DECODE_FAILED = -6,
    PE_ERROR_SEEK_FAILED = -7,
    PE_ERROR_BUFFER_TOO_SMALL = -8,
    PE_ERROR_CANCELLED = -9,
    PE_ERROR_ENCODE_FAILED = -10,
};

// Mirrors PalmierPro.Services.Engine.PreviewSeekMode's Exact/InteractiveScrub split (the
// two AudibleStep* cases are treated identically to Exact HERE on the video-seek path —
// see IVideoEngine.cs's remarks. Their audio scrub feedback is a separate call,
// PE_TimelineScrubAudio (see the Playback / A/V clock section below and
// docs/audio-playback-v1.md §5) — the C# caller issues both calls for those two modes.
enum PE_SeekMode : int32_t
{
    PE_SEEK_EXACT = 0,
    PE_SEEK_INTERACTIVE_SCRUB = 1,
};

enum PE_PixelFormatClass : int32_t
{
    PE_PIXFMT_UNKNOWN = 0,
    PE_PIXFMT_YUV420 = 1,
    PE_PIXFMT_YUV422 = 2,
    PE_PIXFMT_YUV444 = 3,
    PE_PIXFMT_RGB = 4,
    PE_PIXFMT_OTHER = 5,
};

#pragma pack(push, 8)

struct PE_MediaInfo
{
    double durationSeconds;
    int32_t fpsNumerator;
    int32_t fpsDenominator;
    int32_t width;
    int32_t height;
    int32_t pixelFormatClass;   // PE_PixelFormatClass
    int32_t audioChannels;
    int32_t audioSampleRate;
    int32_t hasVideo;           // 0/1
    int32_t hasAudio;           // 0/1
    int32_t hasAlpha;           // 0/1
};

// BGRA32 frame owned by the media handle's internal decode buffer; valid until the
// next PE_DecodeFrameAt call on the same media (or PE_CloseMedia).
struct PE_FrameBuffer
{
    const uint8_t* data;
    int32_t width;
    int32_t height;
    int32_t strideBytes;
};

#pragma pack(pop)

// bgraData is owned by the extraction call's internal scale buffer and is only
// valid for the duration of the callback — copy it if you need to keep it.
typedef void (*PE_ThumbnailCallback)(
    void* userCtx,
    int32_t index,
    double requestedTimeSeconds,
    const uint8_t* bgraData,
    int32_t width,
    int32_t height,
    int32_t strideBytes);

PALMIER_API unsigned int PalmierEngine_GetVersion(void);

PALMIER_API int32_t PE_CreateSession(PE_SessionHandle* outSession);
PALMIER_API int32_t PE_DestroySession(PE_SessionHandle session);

// Returns a UTF-8 pointer owned by the session describing the last error on it;
// valid until the next failing call on the same session or PE_DestroySession.
// Never null (points at an empty string when there's no error yet).
PALMIER_API const char* PE_GetLastErrorMessage(PE_SessionHandle session);

PALMIER_API int32_t PE_OpenMedia(PE_SessionHandle session, const char* utf8Path, PE_MediaHandle* outMedia);
PALMIER_API int32_t PE_CloseMedia(PE_SessionHandle session, PE_MediaHandle media);
PALMIER_API int32_t PE_GetMediaInfo(PE_SessionHandle session, PE_MediaHandle media, PE_MediaInfo* outInfo);

PALMIER_API int32_t PE_DecodeFrameAt(PE_SessionHandle session, PE_MediaHandle media, double timelineSeconds, PE_FrameBuffer* outFrame);

// cancelFlag may be null (never cancelled); when non-null it is polled between
// thumbnails and treated as cancelled once its pointee becomes non-zero (the
// caller owns the flag's memory and may set it from another thread).
PALMIER_API int32_t PE_ExtractThumbnails(
    PE_SessionHandle session,
    PE_MediaHandle media,
    const double* times,
    int32_t count,
    int32_t width,
    int32_t height,
    PE_ThumbnailCallback callback,
    void* userCtx,
    const int32_t* cancelFlag);

// Mono max-magnitude peak reduction over [startSeconds, startSeconds + durationSeconds).
// Raw linear amplitude in [0, 1] per peak — no dB normalization (that stays C#-side,
// mirroring WaveformExtractor.swift's split). outCount <= cap.
PALMIER_API int32_t PE_ExtractPeakEnvelope(
    PE_SessionHandle session,
    PE_MediaHandle media,
    double startSeconds,
    double durationSeconds,
    double peaksPerSecond,
    float* outBuffer,
    int32_t cap,
    int32_t* outCount);

// --- D3D11 presentation (Stage A / E1 harness-scale; DevHarness's SwapChainPanel
// today, the real Preview UI in Stage D) --------------------------------------------
//
// Threading contract (mirrors the Stage D SwapChainPanel row in the Windows port
// plan): PE_AttachSwapChain / PE_ResizeSwapChain / PE_DetachSwapChain are UI-thread
// calls (SwapChainPanel interop and a live DXGI swap chain resize both assume the
// calling thread owns the panel). PE_PresentFrameAt may run on a different thread
// (a present/render loop). One session-scoped mutex serializes all D3D11 immediate-
// context submission — concurrent Present + Resize are therefore safe, but Resize
// blocks until any in-flight Present drains (the plan's "quiesce" step) before
// calling ResizeBuffers and re-attaching via SetSwapChain. Device creation tries
// D3D_DRIVER_TYPE_HARDWARE first, then falls back to D3D_DRIVER_TYPE_WARP explicitly
// (CI runners have no GPU). The device is shared with MediaSource's opportunistic
// D3D11VA decode (see MediaSource.h) — created lazily on first use, by whichever of
// PE_OpenMedia / PE_AttachSwapChain runs first.

// swapChainPanelUnknown is the native IUnknown* backing a WinUI3 SwapChainPanel (on
// the C# side: WinRT.IWinRTObject.NativeObject.ThisPtr on the panel instance). The
// engine QueryInterfaces it for ISwapChainPanelNative itself (WinUISwapChainInterop.h
// — the WinUI3/Windows App SDK interface, not the OS-shipped UWP one of the same
// name) — callers don't need that interface at all.
PALMIER_API int32_t PE_AttachSwapChain(PE_SessionHandle session, void* swapChainPanelUnknown, int32_t width, int32_t height);
PALMIER_API int32_t PE_ResizeSwapChain(PE_SessionHandle session, int32_t width, int32_t height);
PALMIER_API int32_t PE_DetachSwapChain(PE_SessionHandle session);

// Decodes the frame at timelineSeconds and presents it to the attached swap chain
// (stretch-blit to the panel's current size — no aspect-ratio correction yet, see
// the real Preview UI in Stage D). PE_ERROR_INVALID_HANDLE if nothing is attached.
PALMIER_API int32_t PE_PresentFrameAt(PE_SessionHandle session, PE_MediaHandle media, double timelineSeconds);

// Headless, CI-facing golden hook: decodes the frame at timelineSeconds and encodes
// it straight to a PNG file via WIC from the CPU decode buffer — no D3D device or
// swap chain involved, so this always works regardless of GPU/WARP availability.
PALMIER_API int32_t PE_RenderFrameToFile(PE_SessionHandle session, PE_MediaHandle media, double timelineSeconds, const char* utf8PngPath);

// --- Timeline ABI (Stage B / E2) -----------------------------------------------------
//
// Consumes the timeline-snapshot-v1 JSON contract (platforms/windows/docs/timeline-
// snapshot-v1.md), parsed with simdjson (native/third_party/simdjson/, native/
// TimelineSnapshotParser.*). One session can hold multiple open timeline handles
// (per-timeline decoder cache, LRU-capped and evicted independently — see
// EngineSession.h); a timeline handle is only ever valid on the session that opened it.
//
// Everything except PE_OpenTimeline/PE_CloseTimeline takes *only* a PE_TimelineHandle,
// no session — the engine validates the handle itself (TimelineRegistry) rather than
// requiring the caller to also thread the session through every call, matching the
// literal ABI shape the plan calls for. PE_UpdateTimeline/PE_TimelineSeek/
// PE_TimelineAttachSwapChain etc. never block on a render in progress.
//
// Threading: each open timeline owns a dedicated render worker thread implementing the
// scrub machinery described in the plan's "Scrub strategy" — PE_TimelineSeek enqueues
// (PE_SEEK_INTERACTIVE_SCRUB, latest-wins, coalesced to ~30 Hz) or dispatches
// (PE_SEEK_EXACT, immediate, cancels any in-flight interactive compose) and returns
// without waiting for the render to happen. PE_TimelineRenderFrameToFile is the
// exception: fully synchronous, bypassing the render thread/mailbox entirely, for
// deterministic golden-fixture tests.

// Parses snapshotJsonUtf8 and opens a new timeline session under `session`. Multiple
// timelines may be open on one session simultaneously (subject to an LRU eviction cap —
// see EngineSession.h); *outTimeline is valid until PE_CloseTimeline or eviction.
PALMIER_API int32_t PE_OpenTimeline(PE_SessionHandle session, const char* utf8SnapshotJson, PE_TimelineHandle* outTimeline);

// Structural or param change: re-parses snapshotJsonUtf8 and atomically swaps it in.
// Any render already in flight for this timeline keeps using the OLD snapshot to
// completion — this call never blocks on that render, and never interrupts it.
PALMIER_API int32_t PE_UpdateTimeline(PE_TimelineHandle timeline, const char* utf8SnapshotJson);

// E3's Rebuild-vs-RefreshParams split (plan's "Render graph"/ABI section): takes a FULL
// snapshot (same shape as PE_UpdateTimeline), but REUSES the existing decoder/media sessions
// unconditionally — it asserts the new snapshot's media set (the set of distinct clip
// mediaPath values, across every track) is IDENTICAL to the currently-open snapshot's, and
// fails with PE_ERROR_INVALID_ARGUMENT (no swap performed) if it isn't. A media-set change is
// a structural rebuild and must go through PE_UpdateTimeline instead. On success, swaps in the
// new snapshot exactly like PE_UpdateTimeline (same atomic-pointer/in-flight-render contract) —
// callers use this for opacity/transform/crop/blendMode/effects/keyframe param edits that don't
// touch which media a clip points at.
PALMIER_API int32_t PE_TimelineRefreshParams(PE_TimelineHandle timeline, const char* utf8SnapshotJson);

PALMIER_API int32_t PE_CloseTimeline(PE_SessionHandle session, PE_TimelineHandle timeline);

// Valid to call whether or not the timeline is currently playing (PE_TimelinePlay, below) —
// while playing, this rebases the A/V clock to `frame` and playback CONTINUES from there; it
// does not implicitly pause (mirrors the Mac's VideoEngine.seek(to:mode:), whose .exact/
// .interactiveScrub branches never call pause() either — only its AudibleStep* handling does,
// and that is caller policy on the C# side, not something this call enforces). See
// docs/audio-playback-v1.md §3.3.
PALMIER_API int32_t PE_TimelineSeek(PE_TimelineHandle timeline, int64_t frame, int32_t mode);

// Same threading contract as PE_AttachSwapChain/PE_ResizeSwapChain/PE_DetachSwapChain
// (see above) — UI-thread calls; the timeline's own render thread presents
// asynchronously in response to PE_TimelineSeek, serialized against these through the
// owning session's shared D3D11 immediate-context mutex.
PALMIER_API int32_t PE_TimelineAttachSwapChain(PE_TimelineHandle timeline, void* swapChainPanelUnknown, int32_t width, int32_t height);
PALMIER_API int32_t PE_TimelineResizeSwapChain(PE_TimelineHandle timeline, int32_t width, int32_t height);
PALMIER_API int32_t PE_TimelineDetachSwapChain(PE_TimelineHandle timeline);

// Headless golden hook: synchronously composes `frame` and PNG-encodes it, bypassing the
// render thread/mailbox/scrub-tolerance machinery entirely — deterministic, unaffected
// by any concurrent PE_TimelineSeek calls on the same handle.
PALMIER_API int32_t PE_TimelineRenderFrameToFile(PE_TimelineHandle timeline, int64_t frame, const char* utf8PngPath);

// Fired from the timeline's render thread each time it actually composes (and, if a
// swap chain is attached, presents) a frame — in response to PE_TimelineSeek, OR (once
// PE_TimelinePlay has started continuous playback, below) once per frame the playback
// present loop actually presents against the A/V clock. Not fired by
// PE_TimelineRenderFrameToFile (that path is synchronous; the caller already knows
// when it completes). May be invoked from a background thread — marshal to the UI
// thread on the C# side. Pass callback == nullptr to unregister.
typedef void (*PE_PlayheadCallback)(void* userCtx, int64_t frame);
PALMIER_API int32_t PE_TimelineSetPlayheadCallback(PE_TimelineHandle timeline, PE_PlayheadCallback callback, void* userCtx);

// UTF-8 JSON array of media paths the engine itself failed to decode while composing
// (distinct from the builder-side OfflineMediaRefs — see docs/timeline-snapshot-v1.md
// §8). Owned by the timeline; valid until the next call that could invalidate it. Never
// null (points at "[]" when there are none).
PALMIER_API const char* PE_TimelineGetUnprocessableMediaRefsJson(PE_TimelineHandle timeline);

// --- Playback / A/V clock (Stage D / E4.5) -------------------------------------------
//
// Normative spec: docs/audio-playback-v1.md. Summary: the engine mixes every audible
// clip into ONE persistent XAudio2 source voice per open timeline; the master clock
// derives from that voice's SamplesPlayed counter (falling back to a QueryPerformanceCounter
// software clock whenever no clip is audible at the current position, OR no audio device
// exists at all — e.g. a CI runner with no audio endpoint; see doc §3.4). Video presentation
// (the timeline's existing render thread) schedules/drops frames against this same clock
// once PE_TimelinePlay is called — see doc §3.5. None of these calls take a tolerance or
// block on decode/compose; PE_TimelineGetClockFrame in particular never blocks (paused: an
// O(1) return of the frozen rebase frame; playing: a single voice-state/QPC read).

// v1 accepts ONLY 0.0 (paused) or 1.0 (playing forward) — PE_ERROR_INVALID_ARGUMENT for any
// other value (PE_ERROR_INVALID_ARGUMENT, not a silent clamp: Phase 1 has no shuttle/J-K-L
// feature, and a caller must never be able to "successfully" request a rate this build
// cannot honor). The general `rate` primitive exists now — rather than baking "1.0 or 0.0"
// into the ABI shape itself — purely so a future variable-speed-preview feature is a value
// change, not an ABI break; see doc §4. Performs a clock rebase (doc §3.3) to the timeline's
// current clock position, same as PE_TimelinePlay/PE_TimelinePause below.
PALMIER_API int32_t PE_TimelineSetRate(PE_TimelineHandle timeline, double rate);

// Equivalent to PE_TimelineSetRate(timeline, 1.0) / (timeline, 0.0) respectively — kept as
// their own entry points because this is also where the C# surface (IVideoEngine.Play/Pause)
// lands 1:1 with the Mac's VideoEngine.play()/pause() naming. Idempotent: calling Play while
// already playing (or Pause while already paused) succeeds as a no-op, matching AVPlayer's
// own play()/pause() semantics on the Mac. Rebases the clock (doc §3.3): Play does
// FlushSourceBuffers+Start on the persistent voice from the CURRENT (frozen) clock position;
// Pause does Stop+FlushSourceBuffers, freezing the clock at wherever it had reached.
PALMIER_API int32_t PE_TimelinePlay(PE_TimelineHandle timeline);
PALMIER_API int32_t PE_TimelinePause(PE_TimelineHandle timeline);

// Synchronous poll of the current master-clock position — doc §3.2 for the exact formula.
// Well-defined at any point after PE_OpenTimeline (a freshly opened timeline starts paused
// at frame 0, i.e. as if PE_TimelinePause had just been called at frame 0). *outFrame is
// only written on PE_OK.
PALMIER_API int32_t PE_TimelineGetClockFrame(PE_TimelineHandle timeline, int64_t* outFrame);

enum PE_ScrubAudioDirection : int32_t
{
    PE_SCRUB_AUDIO_FORWARD = 0,
    PE_SCRUB_AUDIO_REVERSE = 1,
};

// Short (~50ms), edge-faded windowed audio grab at `frame`, played once through a
// lightweight voice separate from the persistent playback voice — mirrors
// ScrubAudioEngine.scrub/makeGrain/edgeGain on the Mac (doc §5). Uses the same per-clip
// gain formula (Clip.volume × dB keyframe × fades, Track.muted honored, no pan) as normal
// playback — a scrub grain is a miniature instance of the same mix, not a different gain
// path. `direction` is always caller-supplied; native performs no auto-detection from frame
// history (that bookkeeping is caller policy — doc §5). A new call cuts off any
// still-playing grain and starts immediately (latest-wins). Despite the name mirroring the
// AudibleStepForward/Backward PreviewSeekMode cases specifically, this is also the correct
// call for InteractiveScrub (continuous drag) — see doc §5 for exactly which
// PreviewSeekMode cases the C# caller should pair with this call. Callers are expected to
// PE_TimelinePause first (not enforced natively — same class of caller-enforced contract as
// the swap-chain UI-thread requirement below). Always returns PE_OK on a valid handle/
// direction/frame, even when the result is silence (no audible clip at `frame`, or a
// transient decode failure) — a persistently failing source surfaces through
// PE_TimelineGetUnprocessableMediaRefsJson instead, not through this call's return code.
PALMIER_API int32_t PE_TimelineScrubAudio(PE_TimelineHandle timeline, int64_t frame, int32_t direction);

// Cuts off any still-playing scrub grain and drops any pending one — the Exact-settle counterpart
// to PE_TimelineScrubAudio (doc §5). Mirrors the Mac's ScrubAudioEngine.stopScrubbing() on a
// .exact seek (VideoEngine.swift): the future VideoEngine.Seek (C#) calls this on the Exact branch,
// where PE_TimelineScrubAudio is NOT issued, so a scrub gesture that settles with an Exact seek
// cuts its last grain instead of letting it play out. Idempotent and never fails on content
// grounds — always PE_OK on a valid handle, even when no grain has ever played (the lightweight
// scrub voice is created lazily, so this is then a no-op).
PALMIER_API int32_t PE_TimelineStopScrubAudio(PE_TimelineHandle timeline);

// Headless, CI-facing golden hook for the scrub grain (doc §5) — the audio analogue of
// PE_TimelineRenderAudioRange, but for the fixed-length, edge-faded, direction-aware window
// PE_TimelineScrubAudio plays. Synchronously computes that same grain against `timeline`'s
// current snapshot and writes it into outInterleavedStereo (caller-owned, ScrubAudio::
// kGrainFrameCount [2400] × 2 floats — see native/ScrubAudio.h) — no XAudio2 device involved, so
// it is deterministic and works on a device-less CI runner. PE_ERROR_INVALID_ARGUMENT for a null
// buffer; PE_ERROR_INVALID_HANDLE for an unknown/closed timeline or one with no open snapshot yet.
PALMIER_API int32_t PE_TimelineRenderScrubGrain(PE_TimelineHandle timeline, int64_t frame, int32_t direction, float* outInterleavedStereo);

// Fired whenever isPlaying actually transitions: PE_TimelinePlay/PE_TimelineSetRate(…, 1.0)
// → true; PE_TimelinePause/PE_TimelineSetRate(…, 0.0) → false; AND the engine's own
// automatic stop when the master clock reaches the timeline's output duration during
// playback (doc §3.5 — mirrors the Mac's periodic-time-observer auto-pause-at-end, which is
// engine-internal there too, not a UI-side poll). May be invoked from a background thread —
// marshal to the UI thread on the C# side, same contract as PE_PlayheadCallback. Pass
// callback == nullptr to unregister.
typedef void (*PE_IsPlayingCallback)(void* userCtx, int32_t isPlaying);
PALMIER_API int32_t PE_TimelineSetIsPlayingCallback(PE_TimelineHandle timeline, PE_IsPlayingCallback callback, void* userCtx);

// Headless, CI-facing golden hook for the audio mix loop (doc §6) — the audio analogue of
// PE_TimelineRenderFrameToFile. Synchronously mixes the current snapshot's audio for the range
// starting at timeline frame `startFrame` and running `frameCount` sample-frames at 48 kHz,
// writing interleaved stereo Float32 into outInterleavedStereo (caller-owned, frameCount × 2
// floats). No XAudio2 device is involved, so it is deterministic and works on a device-less CI
// runner. A range with no audible clip (or a muted track) yields silence, still returning PE_OK;
// the mix bus is saturation-clamped to [-1, 1] (the device's own ±1.0 clip made explicit — no
// soft limiter, doc §2). PE_ERROR_INVALID_ARGUMENT for a null buffer or frameCount <= 0.
PALMIER_API int32_t PE_TimelineRenderAudioRange(PE_TimelineHandle timeline, int64_t startFrame, int32_t frameCount, float* outInterleavedStereo);

// Master meter tap (Stage E, AudioMeterView) — reads the raw linear-amplitude peak + RMS per
// channel of the most recently mixed audio block, fed by BOTH PE_TimelineRenderAudioRange
// (offline; deterministic, no device) and the live playback fill path (Play()/FillAudio). Values
// are NOT dB and NOT clamped — the C# AudioMeterHub port (PalmierPro.Core.Audio) owns the dB
// mapping/decay/peak-hold/clip-latch ballistics, mirroring the Mac's AudioMeterChannelState
// (Audio/AudioMeter.swift) exactly, so this call only ever reports the raw tap. Lock-free on the
// native side (plain atomics — see native/TimelineSession.h) so a UI poll here never blocks
// behind the audio submission thread's decode work. Reads 0 (silence) for all four before either
// producer has ever run for this timeline. PE_ERROR_INVALID_ARGUMENT if any out pointer is null;
// PE_ERROR_INVALID_HANDLE for an unknown/closed timeline.
PALMIER_API int32_t PE_TimelineGetAudioLevels(PE_TimelineHandle timeline, float* outLeftPeak, float* outLeftRms, float* outRightPeak, float* outRightRms);

// --- Fonts (E4) -----------------------------------------------------------------------
//
// FontRegistry.h/.cpp builds one process-wide IDWriteFactory5 custom font set from the 13
// bundled families (Sources/PalmierPro/Resources/Fonts, referenced not duplicated —
// PalmierPro.Rendering.csproj deploys them to fonts\ next to this DLL). No session/timeline
// handle: the registry has no per-session state, only static bundled content, lazily
// built on first use by whichever caller reaches it first (this probe, or the text/title
// compositor).

// Test/debug-only probe — resolves storedFontName (a TextStyle.fontName value) against the
// bundled registry exactly as the text compositor will (FontRegistry::ResolveFamily) and
// copies the resolved family as NUL-terminated UTF-8 into outFamilyNameUtf8. Always
// resolves to SOME bundled family (see FontRegistry.h's kFallbackFamily) once the registry
// initializes successfully — PE_ERROR_UNKNOWN only if the bundle itself failed to load
// (missing/empty fonts\ directory, DirectWrite factory creation failure).
// PE_ERROR_BUFFER_TOO_SMALL if capacity can't hold the resolved name + NUL.
PALMIER_API int32_t PE_DebugResolveFontFamily(const char* storedFontName, char* outFamilyNameUtf8, int32_t capacity);

// --- Lottie bake (Stage E / E4.7) ------------------------------------------------------
//
// Normative spec: docs/lottie-bake-v1.md. Mirrors the Mac's Preview/LottieVideoGenerator.swift:
// vendored ThorVG (native/third_party/thorvg/ — see THIRD_PARTY_NOTICES.md) rasterizes a
// (plain-JSON) Lottie animation frame-by-frame into a premultiplied BGRA32 buffer;
// PE_EncodeAlphaVideo* muxes those frames into a prores_ks 4444 .mov via FFmpeg.
// PE_BakeLottieVideo is the one-call orchestration entry point PalmierPro.Services.Media.
// ILottieBakeService actually calls (doc §9); PE_EncodeAlphaVideo* is exposed independently
// because it's directly testable with synthetic frames, no ThorVG/Lottie file involved — the
// same "headless golden hook" split PE_TimelineRenderAudioRange already established for the
// audio mix loop (doc §14). A .lottie (dotLottie zip) source is unzipped C#-side before
// reaching either of these calls — native only ever opens a plain-JSON Lottie path; see doc §12.

// Opens a streaming ProRes 4444 .mov encoder at utf8OutputPath. width/height must both be
// positive and EVEN (ProRes 4:4:4:4 requirement — mirrors LottieVideoGenerator.
// clampedForEncoder's even() rounding on the Mac); PE_ERROR_INVALID_ARGUMENT otherwise.
// PE_ERROR_FILE_OPEN_FAILED if utf8OutputPath's directory can't be created/opened for write;
// PE_ERROR_ENCODE_FAILED if avformat/avcodec setup itself fails (this FFmpeg build lacking
// prores_ks, disk full, etc). This call performs no temp-file/atomic-rename dance of its own —
// callers that need atomic "never publish a partial file" semantics (doc §5) open the encoder
// against their own temp path and rename after PE_EncodeAlphaVideoClose succeeds.
PALMIER_API int32_t PE_EncodeAlphaVideoOpen(PE_SessionHandle session, const char* utf8OutputPath, int32_t width, int32_t height, PE_AlphaEncoderHandle* outEncoder);

// Submits one premultiplied BGRA32 frame — identical byte layout to PE_FrameBuffer, and (on
// this little-endian target) byte-identical to ThorVG's own tvg::SwCanvas::ARGB8888 buffer
// (premultiplied, alpha-red-green-blue word order == blue-green-red-alpha byte order) — see
// doc §7: no channel reorder or premultiply pass is needed between ThorVG's raster output and
// this call. presentationSeconds must be STRICTLY GREATER than the previous call's value on
// the same encoder (PE_ERROR_INVALID_ARGUMENT otherwise — every sample needs a distinct,
// increasing timestamp) but need NOT be evenly spaced: a large gap between two calls encodes a
// long hold as one extra sample rather than as repeated frames. This is exactly how the
// freeze-frame tail (doc §6) is realized — a direct port of writeVideo's non-uniform `schedule`
// array on the Mac (LottieVideoGenerator.swift:219-220: the last frame is appended a second
// time at `max(holdTailSeconds, duration + 1)`), not a Windows-specific technique. Copies
// bgraData before returning; the caller may reuse/free its buffer immediately after this call.
PALMIER_API int32_t PE_EncodeAlphaVideoPushFrame(PE_AlphaEncoderHandle encoder, const uint8_t* bgraData, int32_t strideBytes, double presentationSeconds);

// Flushes buffered packets and finalizes the .mov container (moov atom). The output file is
// only a complete, playable ProRes 4444 .mov once this returns PE_OK. Frees the encoder handle
// regardless of return value — the handle is invalid after this call either way.
PALMIER_API int32_t PE_EncodeAlphaVideoClose(PE_AlphaEncoderHandle encoder);

// Cancellation path: discards any buffered/unflushed packets and frees the encoder WITHOUT
// finalizing the container — the file at utf8OutputPath (if anything was ever written to it)
// is left incomplete/unplayable. The caller still owns deleting it; this call does not touch
// the filesystem beyond whatever the OS file handle's own close does.
PALMIER_API int32_t PE_EncodeAlphaVideoAbort(PE_AlphaEncoderHandle encoder);

// Progress-only callback (no pixel data — unlike PE_ThumbnailCallback, callers never need the
// intermediate frames themselves). May fire from the calling thread only (PE_BakeLottieVideo
// is fully synchronous — see below); marshal to the UI thread same as any other engine
// callback if the subscriber touches UI state.
typedef void (*PE_BakeProgressCallback)(void* userCtx, int32_t framesDone, int32_t framesTotal);

// One-call bake: rasterizes every frame of the plain-JSON Lottie file at utf8LottiePath (via
// vendored ThorVG) at targetWidth x targetHeight, appends the freeze-frame hold-tail sample
// (holdTailSeconds — doc §6), and encodes the result to utf8OutputPath via the same
// PE_EncodeAlphaVideo* primitives internally. This IS the entry point
// ILottieBakeService.BakeAsync calls (doc §9) — unlike PE_EncodeAlphaVideo* above, this call
// DOES own its own temp-file + atomic-rename discipline (doc §5): utf8OutputPath is only ever
// created, complete and playable, on PE_OK; any failure or cancellation leaves no file at
// utf8OutputPath at all (its own internal temp file is cleaned up before returning). Runs
// synchronously on the calling thread — callers invoke it from a background Task, exactly like
// every other blocking PE_ call in this header. cancelFlag: identical convention to
// PE_ExtractThumbnails (may be null; polled once per frame). targetWidth/targetHeight need not
// be even — this call rounds them down to even itself (mirrors clampedForEncoder's even()
// exactly) before opening the encoder, so callers pass the size doc §6's sizing rule computes,
// unrounded. PE_ERROR_FILE_OPEN_FAILED if utf8LottiePath can't be parsed as a Lottie
// composition by ThorVG (invalid/non-Lottie JSON) — mirrors LottieVideoError.invalidAnimation
// on the Mac.
PALMIER_API int32_t PE_BakeLottieVideo(
    PE_SessionHandle session,
    const char* utf8LottiePath,
    int32_t targetWidth,
    int32_t targetHeight,
    double holdTailSeconds,
    const char* utf8OutputPath,
    PE_BakeProgressCallback callback,
    void* userCtx,
    const int32_t* cancelFlag);

// Metadata-only probe (native size / duration / frame rate) — no rasterization, no encode, no
// disk cache involved. Closes PalmierPro.Services.Media.EngineMediaProbe.ProbeLottieAsync's
// stub (currently unconditionally returns null — see that file's remarks; doc §11). Mirrors
// LottieVideoGenerator.inspect's metadata half only, not its thumbnail half (a media-panel
// thumbnail for a Lottie asset is a separate, already-existing-shape need — PE_ExtractThumbnails
// operates on a decodable PE_MediaHandle, which a raw .json/.lottie file is not — deferred
// alongside it, not part of this document).
struct PE_LottieInfo
{
    double durationSeconds;
    double width;
    double height;
    double frameRate;
};
PALMIER_API int32_t PE_ProbeLottieMetadata(PE_SessionHandle session, const char* utf8LottiePath, PE_LottieInfo* outInfo);

// --- Color scopes (Stage E / E6) -------------------------------------------------------
//
// Normative spec: docs/color-scopes-v1.md. Ports Preview/VideoEngine.swift's
// histogramYRGB(frame:count:256)/hueHistogram(frame:count:96) — the live scopes behind the
// Inspector Adjust tab's Curves/Hue Curves editors (CurveEditorView.swift/HueCurveEditorView.swift).
// Does NOT port Compositing/ColorScopes.swift's `Scopes` struct (percentile/zone stats, a
// different 12-bin hue histogram) — that backs the Agent `inspect_color` tool and is Phase 2
// (doc §1). GPU compute: downsample the composited frame to a small grid, then a groupshared/
// InterlockedAdd histogram pass over that grid (doc §3) — only the resulting ~4.5 KB buffer is
// read back, never the full frame. No native enable/disable flag exists: this is a pull-based
// call, and "runs only while the Inspector color panel is visible" is satisfied by caller
// discipline (never called except from the future Inspector ViewModel's own visible-tab +
// change-triggered refresh, mirroring exactly when the Mac calls histogramYRGB/hueHistogram —
// see doc §4). Bin counts, normalization (including the joint-max normalize for Y/R/G/B and the
// sqrt-compressed max-normalize for hue), and the BT.709 luma coefficients (NOT Common.hlsl's
// Lum(), which is a different, PDF-blend-mode constant) are specified exactly in doc §2 — this
// header is the ABI shape only, not the numeric contract.

enum PE_ColorScopesConstants : int32_t
{
    PE_COLOR_SCOPES_RGB_BINS = 256,
    PE_COLOR_SCOPES_HUE_BINS = 96,
    PE_COLOR_SCOPES_MAX_GRID_WIDTH = 320,
    PE_COLOR_SCOPES_MAX_GRID_HEIGHT = 180,
};

#pragma pack(push, 8)

// yHistogram/rHistogram/gHistogram/bHistogram are jointly max-normalized (one shared scalar
// across all four, NOT four independent per-channel maxes — doc §2.1). hueHistogram is
// max-normalized then sqrt-compressed (doc §2.2). All five arrays are already in the [0,1] range
// the UI draws directly — no further scaling needed by the caller. frame echoes the requested
// timeline frame back (doc §6) so an async caller can validate a result against its own request.
struct PE_ColorScopesResult
{
    int64_t frame;
    float yHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float rHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float gHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float bHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float hueHistogram[PE_COLOR_SCOPES_HUE_BINS];
};

#pragma pack(pop)

// Synchronously composes `frame` (the full timeline composite — every visible track/clip's
// effect chain, not an isolated single-clip render, doc §2.3) and returns its color scopes.
// Threading contract mirrors PE_TimelineRenderFrameToFile exactly (doc §5): bypasses the render
// thread's seek mailbox entirely (deterministic, unaffected by a concurrent PE_TimelineSeek on
// the same handle), serialized against every other D3D11 call on this session through the
// existing shared immediate-context mutex (see the D3D11 presentation section above), and is safe
// to call from a background thread — it has no swap-chain/window-handle dependency, so unlike
// PE_AttachSwapChain/PE_TimelineAttachSwapChain this is NOT a UI-thread-only call. Callers should
// invoke it off the UI thread regardless, since the compose + GPU readback cost is not free (doc
// §5). PE_ERROR_INVALID_ARGUMENT for a null outResult; PE_ERROR_INVALID_HANDLE for an unknown/
// closed timeline; otherwise the same PE_Status values PE_TimelineRenderFrameToFile's compose
// step can already produce. *outResult is only written on PE_OK.
PALMIER_API int32_t PE_TimelineComputeColorScopes(PE_TimelineHandle timeline, int64_t frame, PE_ColorScopesResult* outResult);
