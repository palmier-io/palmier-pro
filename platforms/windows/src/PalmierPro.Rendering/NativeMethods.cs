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

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineAttachSwapChain(nint timeline, nint swapChainPanelUnknown, int width, int height);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineResizeSwapChain(nint timeline, int width, int height);

    [LibraryImport(EngineLibrary)]
    internal static partial int PE_TimelineDetachSwapChain(nint timeline);

    [LibraryImport(EngineLibrary, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PE_TimelineRenderFrameToFile(nint timeline, long frame, string utf8PngPath);

    [LibraryImport(EngineLibrary)]
    internal static unsafe partial int PE_TimelineSetPlayheadCallback(
        nint timeline, delegate* unmanaged[Cdecl]<nint, long, void> callback, nint userCtx);

    // Owned by the timeline; do not free. Valid until the next call that could
    // invalidate it — copy out immediately (mirrors PE_GetLastErrorMessage's contract).
    [LibraryImport(EngineLibrary)]
    internal static partial nint PE_TimelineGetUnprocessableMediaRefsJson(nint timeline);
}
