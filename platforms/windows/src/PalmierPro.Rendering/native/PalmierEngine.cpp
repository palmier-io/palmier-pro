#include "include/palmier_engine.h"
#include "EngineSession.h"
#include "MediaSource.h"

#include <new>

namespace
{
    EngineSession* AsSession(PE_SessionHandle h) { return reinterpret_cast<EngineSession*>(h); }
    MediaSource* AsMedia(PE_MediaHandle h) { return reinterpret_cast<MediaSource*>(h); }
}

unsigned int PalmierEngine_GetVersion(void)
{
    return 1;
}

int32_t PE_CreateSession(PE_SessionHandle* outSession)
{
    if (!outSession)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    auto* session = new (std::nothrow) EngineSession();
    if (!session)
    {
        return PE_ERROR_UNKNOWN;
    }
    *outSession = reinterpret_cast<PE_SessionHandle>(session);
    return PE_OK;
}

int32_t PE_DestroySession(PE_SessionHandle session)
{
    if (!session)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    delete AsSession(session);
    return PE_OK;
}

const char* PE_GetLastErrorMessage(PE_SessionHandle session)
{
    if (!session)
    {
        return "";
    }
    return AsSession(session)->LastErrorMessage();
}

int32_t PE_OpenMedia(PE_SessionHandle session, const char* utf8Path, PE_MediaHandle* outMedia)
{
    if (!session || !utf8Path || !outMedia)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    try
    {
        return s->OpenMedia(utf8Path, outMedia);
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
}

int32_t PE_CloseMedia(PE_SessionHandle session, PE_MediaHandle media)
{
    if (!session || !media)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    return AsSession(session)->CloseMedia(media);
}

int32_t PE_GetMediaInfo(PE_SessionHandle session, PE_MediaHandle media, PE_MediaInfo* outInfo)
{
    if (!session || !media || !outInfo)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    MediaSource* m = s->Resolve(media);
    if (!m)
    {
        s->SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }
    *outInfo = m->Info();
    return PE_OK;
}

int32_t PE_DecodeFrameAt(PE_SessionHandle session, PE_MediaHandle media, double timelineSeconds, PE_FrameBuffer* outFrame)
{
    if (!session || !media || !outFrame)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    MediaSource* m = s->Resolve(media);
    if (!m)
    {
        s->SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }

    std::string error;
    try
    {
        if (!m->DecodeFrameAt(timelineSeconds, *outFrame, error))
        {
            s->SetLastError(error);
            return PE_ERROR_DECODE_FAILED;
        }
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
    s->ClearLastError();
    return PE_OK;
}

int32_t PE_ExtractThumbnails(
    PE_SessionHandle session,
    PE_MediaHandle media,
    const double* times,
    int32_t count,
    int32_t width,
    int32_t height,
    PE_ThumbnailCallback callback,
    void* userCtx,
    const int32_t* cancelFlag)
{
    if (!session || !media || !times || !callback || count <= 0)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    MediaSource* m = s->Resolve(media);
    if (!m)
    {
        s->SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }

    std::string error;
    try
    {
        if (!m->ExtractThumbnails(times, count, width, height, callback, userCtx, cancelFlag, error))
        {
            s->SetLastError(error);
            return PE_ERROR_DECODE_FAILED;
        }
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }

    if (cancelFlag && *cancelFlag != 0)
    {
        return PE_ERROR_CANCELLED;
    }
    s->ClearLastError();
    return PE_OK;
}

int32_t PE_ExtractPeakEnvelope(
    PE_SessionHandle session,
    PE_MediaHandle media,
    double startSeconds,
    double durationSeconds,
    double peaksPerSecond,
    float* outBuffer,
    int32_t cap,
    int32_t* outCount)
{
    if (!session || !media || !outBuffer || !outCount || cap <= 0)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    MediaSource* m = s->Resolve(media);
    if (!m)
    {
        s->SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }

    std::string error;
    try
    {
        if (!m->ExtractPeakEnvelope(startSeconds, durationSeconds, peaksPerSecond, outBuffer, cap, *outCount, error))
        {
            s->SetLastError(error);
            return PE_ERROR_DECODE_FAILED;
        }
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
    s->ClearLastError();
    return PE_OK;
}

int32_t PE_AttachSwapChain(PE_SessionHandle session, void* swapChainPanelUnknown, int32_t width, int32_t height)
{
    if (!session || !swapChainPanelUnknown || width <= 0 || height <= 0)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    try
    {
        return s->AttachSwapChain(swapChainPanelUnknown, width, height);
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
}

int32_t PE_ResizeSwapChain(PE_SessionHandle session, int32_t width, int32_t height)
{
    if (!session || width <= 0 || height <= 0)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    try
    {
        return s->ResizeSwapChain(width, height);
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
}

int32_t PE_DetachSwapChain(PE_SessionHandle session)
{
    if (!session)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    try
    {
        return s->DetachSwapChain();
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
}

int32_t PE_PresentFrameAt(PE_SessionHandle session, PE_MediaHandle media, double timelineSeconds)
{
    if (!session || !media)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    try
    {
        return s->PresentFrameAt(media, timelineSeconds);
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
}

int32_t PE_RenderFrameToFile(PE_SessionHandle session, PE_MediaHandle media, double timelineSeconds, const char* utf8PngPath)
{
    if (!session || !media || !utf8PngPath)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);
    try
    {
        return s->RenderFrameToFile(media, timelineSeconds, utf8PngPath);
    }
    catch (const std::exception& ex)
    {
        s->SetLastError(ex.what());
        return PE_ERROR_UNKNOWN;
    }
}
