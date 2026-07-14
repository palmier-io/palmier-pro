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
