#include "LottieBaker.h"
#include "AlphaVideoEncoder.h"
#include "EngineSession.h"
#include "LottieRasterizer.h"

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <sstream>
#include <string>
#include <vector>

namespace
{
    // Mirrors LottieVideoGenerator.clampedForEncoder/even() on the Mac exactly (doc §6/§8):
    // floor each dimension to >= 1, scale proportionally so the longest side is <= 4096, then
    // floor to the nearest even value (>= 2) — ProRes 4:4:4:4 requires even width/height.
    constexpr double kMaxEncoderDimension = 4096.0;

    int32_t EvenFloor(double value)
    {
        int32_t pixels = static_cast<int32_t>(std::floor(value));
        return std::max(2, pixels - (pixels % 2));
    }

    void ClampForEncoder(int32_t inWidth, int32_t inHeight, int32_t& outWidth, int32_t& outHeight)
    {
        double w = std::max(1, inWidth);
        double h = std::max(1, inHeight);
        double longest = std::max(w, h);
        double scale = longest > kMaxEncoderDimension ? kMaxEncoderDimension / longest : 1.0;
        outWidth = EvenFloor(w * scale);
        outHeight = EvenFloor(h * scale);
    }

    // A fresh, process-unique temp filename next to outputPath — PE_BakeLottieVideo's own internal
    // temp-file+rename discipline (doc §8): outputPath is only ever created, complete and playable,
    // on PE_OK. Not a shared/reused name, so no cross-call collision risk.
    std::atomic<uint64_t> g_tempCounter{0};

    std::string TempPathNextTo(const std::string& outputPath)
    {
        uint64_t id = (static_cast<uint64_t>(::GetCurrentProcessId()) << 32) ^ ::GetTickCount64() ^ g_tempCounter.fetch_add(1);
        std::ostringstream oss;
        oss << outputPath << ".baketmp" << std::hex << id;
        return oss.str();
    }

    void DeleteFileIfExists(const std::string& path)
    {
        ::DeleteFileA(path.c_str());
    }

    EngineSession* AsSession(PE_SessionHandle h)
    {
        return reinterpret_cast<EngineSession*>(h);
    }
}

int32_t PE_ProbeLottieMetadata(PE_SessionHandle session, const char* utf8LottiePath, PE_LottieInfo* outInfo)
{
    if (!session || !utf8LottiePath || !*utf8LottiePath || !outInfo)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);

    LottieRasterizer rasterizer;
    if (!rasterizer.Open(utf8LottiePath))
    {
        s->SetLastError(std::string("PE_ProbeLottieMetadata: could not open '") + utf8LottiePath + "' as a Lottie composition");
        return PE_ERROR_FILE_OPEN_FAILED;
    }

    outInfo->durationSeconds = rasterizer.DurationSeconds();
    outInfo->width = static_cast<double>(rasterizer.NativeWidth());
    outInfo->height = static_cast<double>(rasterizer.NativeHeight());
    outInfo->frameRate = rasterizer.FrameRate();
    return PE_OK;
}

int32_t PE_BakeLottieVideo(
    PE_SessionHandle session,
    const char* utf8LottiePath,
    int32_t targetWidth,
    int32_t targetHeight,
    double holdTailSeconds,
    const char* utf8OutputPath,
    PE_BakeProgressCallback callback,
    void* userCtx,
    const int32_t* cancelFlag)
{
    if (!session || !utf8LottiePath || !*utf8LottiePath || !utf8OutputPath || !*utf8OutputPath)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    EngineSession* s = AsSession(session);

    LottieRasterizer rasterizer;
    if (!rasterizer.Open(utf8LottiePath))
    {
        s->SetLastError(std::string("PE_BakeLottieVideo: could not open '") + utf8LottiePath + "' as a Lottie composition");
        return PE_ERROR_FILE_OPEN_FAILED;
    }

    int32_t width, height;
    ClampForEncoder(targetWidth, targetHeight, width, height);

    const int32_t frameCount = rasterizer.FrameCount();
    const double duration = rasterizer.DurationSeconds();
    const double fps = std::max(1.0, rasterizer.FrameRate());
    const int32_t strideBytes = width * 4;

    std::string tempPath = TempPathNextTo(utf8OutputPath);

    AlphaVideoEncoder encoder(s);
    int32_t status = encoder.Open(tempPath, width, height);
    if (status != PE_OK)
    {
        DeleteFileIfExists(tempPath);
        return status;
    }

    std::vector<uint8_t> frameBuffer(static_cast<size_t>(strideBytes) * static_cast<size_t>(height), 0);

    for (int32_t frame = 0; frame < frameCount; ++frame)
    {
        if (cancelFlag && *cancelFlag != 0)
        {
            encoder.Abort();
            DeleteFileIfExists(tempPath);
            return PE_ERROR_CANCELLED;
        }

        if (!rasterizer.RasterizeFrame(frame, width, height, frameBuffer.data(), strideBytes))
        {
            s->SetLastError("PE_BakeLottieVideo: ThorVG failed to rasterize frame " + std::to_string(frame));
            encoder.Abort();
            DeleteFileIfExists(tempPath);
            return PE_ERROR_DECODE_FAILED;
        }

        double presentationSeconds = static_cast<double>(frame) / fps;
        status = encoder.PushFrame(frameBuffer.data(), strideBytes, presentationSeconds);
        if (status != PE_OK)
        {
            encoder.Abort();
            DeleteFileIfExists(tempPath);
            return status;
        }

        if (callback)
        {
            callback(userCtx, frame + 1, frameCount);
        }
    }

    // Freeze-frame hold tail (doc §6/§8): the already-rasterized last frame, held out to a
    // far-future timestamp — one extra sample, not repeated frames. Mirrors writeVideo's
    // `schedule` array (LottieVideoGenerator.swift:219-220) exactly.
    double lastFrameSeconds = static_cast<double>(frameCount - 1) / fps;
    double holdSeconds = std::max(holdTailSeconds, duration + 1.0);
    if (holdSeconds <= lastFrameSeconds)
    {
        holdSeconds = lastFrameSeconds + 1.0;
    }
    status = encoder.PushFrame(frameBuffer.data(), strideBytes, holdSeconds);
    if (status != PE_OK)
    {
        encoder.Abort();
        DeleteFileIfExists(tempPath);
        return status;
    }

    status = encoder.Close();
    if (status != PE_OK)
    {
        DeleteFileIfExists(tempPath);
        return status;
    }

    if (!::MoveFileExA(tempPath.c_str(), utf8OutputPath, MOVEFILE_REPLACE_EXISTING))
    {
        s->SetLastError("PE_BakeLottieVideo: could not rename temp bake output to '" + std::string(utf8OutputPath) + "' (GetLastError=" + std::to_string(::GetLastError()) + ")");
        DeleteFileIfExists(tempPath);
        return PE_ERROR_FILE_OPEN_FAILED;
    }

    return PE_OK;
}

int32_t PE_RenderLottieThumbnail(const char* utf8LottiePath, int32_t width, int32_t height, uint8_t* outBgra, int32_t strideBytes)
{
    if (!utf8LottiePath || !*utf8LottiePath || width <= 0 || height <= 0 || !outBgra)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }

    LottieRasterizer rasterizer;
    if (!rasterizer.Open(utf8LottiePath))
    {
        return PE_ERROR_FILE_OPEN_FAILED;
    }
    if (!rasterizer.RasterizeFrame(0, width, height, outBgra, strideBytes))
    {
        return PE_ERROR_DECODE_FAILED;
    }
    return PE_OK;
}
