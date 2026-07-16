using System.Runtime.InteropServices;

namespace PalmierPro.Rendering;

[StructLayout(LayoutKind.Sequential)]
internal struct PE_MediaInfo
{
    public double DurationSeconds;
    public int FpsNumerator;
    public int FpsDenominator;
    public int Width;
    public int Height;
    public int PixelFormatClass;
    public int AudioChannels;
    public int AudioSampleRate;
    public int HasVideo;
    public int HasAudio;
    public int HasAlpha;
}

[StructLayout(LayoutKind.Sequential)]
internal struct PE_FrameBuffer
{
    public nint Data;
    public int Width;
    public int Height;
    public int StrideBytes;
}

// Mirrors native PE_LottieInfo (palmier_engine.h, docs/lottie-bake-v1.md §8).
[StructLayout(LayoutKind.Sequential)]
internal struct PE_LottieInfo
{
    public double DurationSeconds;
    public double Width;
    public double Height;
    public double FrameRate;
}

// Mirrors native PE_ColorScopesResult (palmier_engine.h) — see docs/color-scopes-v1.md §2 for
// the bin counts/normalization these fixed arrays already carry (no further scaling needed by
// the caller). `unsafe`/`fixed`: the native struct embeds its float arrays inline, returned by
// value across P/Invoke — see ColorScopesResult.cs's remarks on why that rules out a
// copy-vs-alias choice on the managed side.
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct PE_ColorScopesResult
{
    public long Frame;
    public fixed float YHistogram[256];
    public fixed float RHistogram[256];
    public fixed float GHistogram[256];
    public fixed float BHistogram[256];
    public fixed float HueHistogram[96];
}

// Mirrors native/include/palmier_engine.h's PE_Status. 0 = ok, negative = error.
internal enum PE_Status
{
    Ok = 0,
    ErrorUnknown = -1,
    ErrorInvalidArgument = -2,
    ErrorInvalidHandle = -3,
    ErrorFileOpenFailed = -4,
    ErrorNoStream = -5,
    ErrorDecodeFailed = -6,
    ErrorSeekFailed = -7,
    ErrorBufferTooSmall = -8,
    ErrorCancelled = -9,
    ErrorEncodeFailed = -10,
}

// Flat C ABI surface for PalmierEngine.dll (built via native/PalmierEngine.vcxproj, not the dotnet CLI).
internal static partial class NativeMethods
{
    private const string EngineLibrary = "PalmierEngine.dll";

    [LibraryImport(EngineLibrary)]
    internal static partial uint PalmierEngine_GetVersion();

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_CreateSession(out nint outSession);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_DestroySession(nint session);

    // Returned pointer is owned by the session (valid until its next failing call or
    // PE_DestroySession) — do not free it.
    [LibraryImport(EngineLibrary)]
    internal static partial nint PE_GetLastErrorMessage(nint session);

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_OpenMedia(nint session, string utf8Path, out nint outMedia);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_CloseMedia(nint session, nint media);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_GetMediaInfo(nint session, nint media, out PE_MediaInfo outInfo);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_DecodeFrameAt(nint session, nint media, double timelineSeconds, out PE_FrameBuffer outFrame);

    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_ExtractThumbnails(
        nint session,
        nint media,
        double* times,
        int count,
        int width,
        int height,
        delegate* unmanaged[Cdecl]<nint, int, double, byte*, int, int, int, void> callback,
        nint userCtx,
        int* cancelFlag);

    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_ExtractPeakEnvelope(
        nint session,
        nint media,
        double startSeconds,
        double durationSeconds,
        double peaksPerSecond,
        float* outBuffer,
        int cap,
        out int outCount);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_AttachSwapChain(nint session, nint swapChainPanelUnknown, int width, int height);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_ResizeSwapChain(nint session, int width, int height);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_DetachSwapChain(nint session);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_PresentFrameAt(nint session, nint media, double timelineSeconds);

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_RenderFrameToFile(nint session, nint media, double timelineSeconds, string utf8PngPath);

    // --- Timeline ABI (Stage B / E2) -------------------------------------------------

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_OpenTimeline(nint session, string utf8SnapshotJson, out nint outTimeline);

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_UpdateTimeline(nint timeline, string utf8SnapshotJson);

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_TimelineRefreshParams(nint timeline, string utf8SnapshotJson);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_CloseTimeline(nint session, nint timeline);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineSeek(nint timeline, long frame, int mode);

    // E4.5 scrub slice (docs/audio-playback-v1.md §5): latest-wins windowed audio grab at
    // `frame`, played once through a lightweight voice separate from the persistent playback
    // voice. `direction` is a PE_ScrubAudioDirection raw value (0 = forward, 1 = reverse).
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineScrubAudio(nint timeline, long frame, int direction);

    // E4.5 scrub slice (docs/audio-playback-v1.md §5): the Exact-settle counterpart to
    // PE_TimelineScrubAudio — cuts off any still-playing scrub grain (mirrors the Mac's
    // ScrubAudioEngine.stopScrubbing() on a .exact seek). Idempotent; never fails on content grounds.
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineStopScrubAudio(nint timeline);

    // Offline golden hook for the scrub grain (docs/audio-playback-v1.md §5) — the audio analogue
    // of PE_TimelineRenderAudioRange: fills outInterleavedStereo (ScrubAudio::kGrainFrameCount ×
    // 2 floats, caller-owned) with the same edge-faded, direction-aware grain
    // PE_TimelineScrubAudio would play. No XAudio2 device involved.
    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_TimelineRenderScrubGrain(nint timeline, long frame, int direction, float* outInterleavedStereo);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineAttachSwapChain(nint timeline, nint swapChainPanelUnknown, int width, int height);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineResizeSwapChain(nint timeline, int width, int height);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineDetachSwapChain(nint timeline);

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_TimelineRenderFrameToFile(nint timeline, long frame, string utf8PngPath);

    // E6 color scopes (docs/color-scopes-v1.md): synchronous GPU compute of `frame`'s live
    // Y/R/G/B (256-bin) + hue (96-bin) histograms — same threading contract as
    // PE_TimelineRenderFrameToFile (bypasses the render thread/mailbox).
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineComputeColorScopes(nint timeline, long frame, out PE_ColorScopesResult outResult);

    // Offline audio mix (docs/audio-playback-v1.md §6): fills outInterleavedStereo (frameCount × 2
    // floats, caller-owned) with the 48 kHz stereo mix for the range at timeline `startFrame`.
    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_TimelineRenderAudioRange(nint timeline, long startFrame, int frameCount, float* outInterleavedStereo);

    // Master meter tap (Stage E, AudioMeterView): raw linear-amplitude peak + RMS per channel from
    // the most recently mixed audio block (fed by both PE_TimelineRenderAudioRange and live
    // playback). Lock-free on the native side — never blocks behind the audio submission thread.
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineGetAudioLevels(nint timeline, out float outLeftPeak, out float outLeftRms, out float outRightPeak, out float outRightRms);

    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_TimelineSetPlayheadCallback(
        nint timeline, delegate* unmanaged[Cdecl]<nint, long, void> callback, nint userCtx);

    // --- Playback / A/V clock (Stage D / E4.5, docs/audio-playback-v1.md §3, §4) -------

    // Rejects any rate other than 0.0 (paused) / 1.0 (playing) with PE_ERROR_INVALID_ARGUMENT.
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineSetRate(nint timeline, double rate);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelinePlay(nint timeline);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelinePause(nint timeline);

    // Synchronous master-clock poll — never blocks. *outFrame written only on PE_OK.
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineGetClockFrame(nint timeline, out long outFrame);

    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_TimelineSetIsPlayingCallback(
        nint timeline, delegate* unmanaged[Cdecl]<nint, int, void> callback, nint userCtx);

    // Test/debug-only probe (declared in native/TimelineSession.h, NOT the normative palmier_engine.h
    // ABI — same one-slice-test-seam convention as PE_PlaybackClockSelfTest): writes 1 if the master
    // clock is on the sample-locked audio path, 0 on the QPC software fallback. Lets the device-gated
    // play→pause→play test assert the audio clock re-engages after re-play (docs/audio-playback-v1.md §3.4).
    [LibraryImport(EngineLibrary)]
    internal static partial int PE_DebugTimelineUsingAudioClock(nint timeline, out int outUsingAudioClock);

    // Owned by the timeline; do not free. Valid until the next call that could
    // invalidate it — copy out immediately (mirrors PE_GetLastErrorMessage's contract).
    [LibraryImport(EngineLibrary)]
    internal static partial nint PE_TimelineGetUnprocessableMediaRefsJson(nint timeline);

    // --- Fonts (E4) -------------------------------------------------------------------

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static unsafe partial int PE_DebugResolveFontFamily(string storedFontName, byte* outFamilyNameUtf8, int capacity);

    // --- Lottie bake / alpha video encode (Stage E / E4.7, docs/lottie-bake-v1.md §7, §8) ---

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_EncodeAlphaVideoOpen(nint session, string utf8OutputPath, int width, int height, out nint outEncoder);

    // bgraData is premultiplied BGRA32, width*height pixels at strideBytes. presentationSeconds
    // must strictly increase between calls — see AlphaVideoEncoder.h's PushFrame doc comment.
    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_EncodeAlphaVideoPushFrame(nint encoder, byte* bgraData, int strideBytes, double presentationSeconds);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_EncodeAlphaVideoClose(nint encoder);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_EncodeAlphaVideoAbort(nint encoder);

    // One-call bake orchestration (docs/lottie-bake-v1.md §8) — rasterizes via vendored ThorVG and
    // encodes via the PE_EncodeAlphaVideo* primitives above internally. Runs synchronously on the
    // calling thread; callers invoke from a background Task. cancelFlag: same polled-once-per-frame
    // convention as PE_ExtractThumbnails.
    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static unsafe partial int PE_BakeLottieVideo(
        nint session,
        string utf8LottiePath,
        int targetWidth,
        int targetHeight,
        double holdTailSeconds,
        string utf8OutputPath,
        delegate* unmanaged[Cdecl]<nint, int, int, void> callback,
        nint userCtx,
        int* cancelFlag);

    // Metadata-only probe (docs/lottie-bake-v1.md §8) — no rasterization, no encode, no disk cache.
    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_ProbeLottieMetadata(nint session, string utf8LottiePath, out PE_LottieInfo outInfo);

    // Additive, beyond docs/lottie-bake-v1.md's own frozen contract (named there as an explicit v1
    // follow-up, §11) — backs MediaVisualCache's Lottie filmstrip-tile need via the same vendored
    // ThorVG rasterizer (native/LottieBaker.cpp), no session/disk cache involved. Rasterizes frame 0.
    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static unsafe partial int PE_RenderLottieThumbnail(string utf8LottiePath, int width, int height, byte* outBgra, int strideBytes);
}
