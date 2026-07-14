#pragma once

#include "include/palmier_engine.h"

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

extern "C"
{
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
}

struct ID3D11Device;

// Lazily-opened AVFormatContext/AVCodecContext pair for one media file. Tries
// D3D11VA hardware decode opportunistically (sharing the session's D3D11 device;
// see EngineSession::EnsureGraphicsDevice) and falls back to CPU software decode
// automatically — on open (no hwaccel config for the codec, or device/hwaccel init
// failure) and transparently either way by the time DecodeFrameAt/ExtractThumbnails
// hand back a frame: hw frames are transferred to system memory before the
// existing sws_scale-to-BGRA path runs, so callers never see the difference.
// Zero-copy decode-straight-to-texture is deferred to E2.
//
// Not safe to call concurrently from multiple threads on the same instance
// (guarded by mutex_ defensively, but callers should still serialize per media).
class MediaSource
{
public:
    MediaSource() = default;
    ~MediaSource();

    MediaSource(const MediaSource&) = delete;
    MediaSource& operator=(const MediaSource&) = delete;

    // sharedDevice may be null (no hw decode attempted); deviceIsHardware gates the
    // attempt off entirely on a WARP device, which has no video decode engine.
    bool Open(const std::string& utf8Path, ID3D11Device* sharedDevice, bool deviceIsHardware, std::string& outError);

    const PE_MediaInfo& Info() const { return info_; }

    bool DecodeFrameAt(double timelineSeconds, PE_FrameBuffer& outFrame, std::string& outError);

    // approximate=true is the interactive-scrub "tolerance seek" fast path: seeks
    // backward to the nearest keyframe and returns that keyframe's decoded frame
    // immediately, without decoding forward toward timelineSeconds — cheap, used while
    // actively scrubbing. approximate=false is the existing exact-decode behavior
    // DecodeFrameAt delegates to. cancelFlag (may be null) is polled between packets in
    // the forward-decode loop (exact mode only — approximate mode never enters it); once
    // it reads non-zero the call returns false with outError == "cancelled".
    //
    // Unlike the Mac's load-adaptive tolerance (SeekCoordinator.InteractiveTolerance:
    // min(0.75s, 0.15s × active layers)), `approximate` is a plain boolean — there is no
    // notion of "decode forward until within N seconds of target." A single-layer scrub
    // therefore always snaps a full GOP back to the keyframe here, where the Mac would
    // hold much closer to the requested time. Accepted v1 simplification — see
    // VideoEngine.cs's Seek() remarks.
    bool DecodeFrameAtEx(double timelineSeconds, bool approximate, const std::atomic<int32_t>* cancelFlag,
        PE_FrameBuffer& outFrame, std::string& outError);

    bool ExtractThumbnails(
        const double* times,
        int32_t count,
        int32_t width,
        int32_t height,
        PE_ThumbnailCallback callback,
        void* userCtx,
        const int32_t* cancelFlag,
        std::string& outError);

    bool ExtractPeakEnvelope(
        double startSeconds,
        double durationSeconds,
        double peaksPerSecond,
        float* outBuffer,
        int32_t cap,
        int32_t& outCount,
        std::string& outError);

private:
    std::mutex mutex_;

    AVFormatContext* formatCtx_ = nullptr;
    int videoStreamIndex_ = -1;
    int audioStreamIndex_ = -1;
    AVCodecContext* videoCodecCtx_ = nullptr;
    AVCodecContext* audioCodecCtx_ = nullptr;

    PE_MediaInfo info_{};

    // Reusable decode buffer for DecodeFrameAt (session/media-owned, per ABI contract).
    std::vector<uint8_t> bgraBuffer_;
    SwsContext* decodeSwsCtx_ = nullptr;

    // D3D11VA opportunistic hw decode state. hwDeviceCtx_ holds its own AddRef on the
    // shared ID3D11Device (via AVD3D11VADeviceContext::device), so it stays valid
    // independent of EngineSession's own device lifetime. hwPixFmt_ is AV_PIX_FMT_NONE
    // when hw decode isn't in use for this media.
    AVBufferRef* hwDeviceCtx_ = nullptr;
    AVPixelFormat hwPixFmt_ = AV_PIX_FMT_NONE;

    void Close();
    void FillInfo();

    bool OpenVideoDecoderHardware(const AVCodec* decoder, AVCodecParameters* params, ID3D11Device* device, std::string& outError);
    bool OpenVideoDecoderSoftware(const AVCodec* decoder, AVCodecParameters* params, std::string& outError);
    static AVPixelFormat GetHwFormat(AVCodecContext* ctx, const AVPixelFormat* pixFmts);

    // Seeks to the nearest keyframe at/before targetPts. approximate=false (the original
    // behavior) decodes forward until a frame at/after targetPts is produced (or EOF,
    // returning the last decoded frame), polling cancelFlag between packets.
    // approximate=true returns as soon as the first frame past the backward seek is
    // decoded — that frame is the keyframe itself, i.e. the "nearest preceding keyframe"
    // tolerance-seek result — and never consults cancelFlag (there is no forward-decode
    // loop to cancel). The returned frame may be a hw (D3D11) frame — see
    // MaterializeSystemMemoryFrame.
    bool SeekAndDecodeVideo(int64_t targetPts, bool approximate, const std::atomic<int32_t>* cancelFlag,
        AVFrame* outFrame, std::string& outError);

    // If decoded is a hw frame, transfers it into transferScratch (system memory) and
    // returns that; otherwise returns decoded unchanged. transferScratch is reused
    // across calls (unref'd each time) to avoid a per-frame allocation.
    bool MaterializeSystemMemoryFrame(AVFrame* decoded, AVFrame* transferScratch, AVFrame*& outUsable, std::string& outError);

    // sws_getCachedContext reuses/replaces *swsCtx as needed; caller owns the pointer.
    static bool ConvertFrameToBgra(AVFrame* frame, int dstWidth, int dstHeight, uint8_t* dst, int dstStride,
        SwsContext*& swsCtx, std::string& outError);
};
