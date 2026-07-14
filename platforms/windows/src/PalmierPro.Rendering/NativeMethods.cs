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
}
