#include "AlphaVideoEncoder.h"
#include "EngineSession.h"

#include <cmath>
#include <mutex>
#include <unordered_set>

namespace
{
    std::string AvErrorToString(int errnum)
    {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(errnum, buf, sizeof(buf));
        return std::string(buf);
    }

    // Process-wide validity set for AlphaVideoEncoder* handles — see the class comment in
    // AlphaVideoEncoder.h for why this exists (PushFrame/Close/Abort have no session to
    // validate a handle through, unlike PE_MediaHandle/EngineSession's own map).
    std::mutex g_registryMutex;
    std::unordered_set<AlphaVideoEncoder*> g_liveEncoders;
}

AlphaVideoEncoder::AlphaVideoEncoder(EngineSession* owner) : owner_(owner)
{
    std::lock_guard<std::mutex> lock(g_registryMutex);
    g_liveEncoders.insert(this);
}

AlphaVideoEncoder::~AlphaVideoEncoder()
{
    ReleaseResources();
    std::lock_guard<std::mutex> lock(g_registryMutex);
    g_liveEncoders.erase(this);
}

AlphaVideoEncoder* AlphaVideoEncoder::Resolve(AlphaVideoEncoder* candidate)
{
    std::lock_guard<std::mutex> lock(g_registryMutex);
    return g_liveEncoders.count(candidate) ? candidate : nullptr;
}

void AlphaVideoEncoder::SetLastError(const std::string& message)
{
    if (owner_)
    {
        owner_->SetLastError(message);
    }
}

int32_t AlphaVideoEncoder::Open(const std::string& utf8OutputPath, int32_t width, int32_t height)
{
    if (width <= 0 || height <= 0 || (width % 2) != 0 || (height % 2) != 0)
    {
        SetLastError("PE_EncodeAlphaVideoOpen: width/height must be positive and even");
        return PE_ERROR_INVALID_ARGUMENT;
    }

    int ret = avformat_alloc_output_context2(&formatCtx_, nullptr, "mov", utf8OutputPath.c_str());
    if (ret < 0 || !formatCtx_)
    {
        SetLastError("avformat_alloc_output_context2 failed: " + AvErrorToString(ret));
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }

    const AVCodec* encoder = avcodec_find_encoder_by_name("prores_ks");
    if (!encoder)
    {
        SetLastError("prores_ks encoder not available in this ffmpeg build");
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }

    stream_ = avformat_new_stream(formatCtx_, nullptr);
    if (!stream_)
    {
        SetLastError("avformat_new_stream failed");
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }

    codecCtx_ = avcodec_alloc_context3(encoder);
    if (!codecCtx_)
    {
        SetLastError("avcodec_alloc_context3 failed");
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }

    codecCtx_->width = width;
    codecCtx_->height = height;
    codecCtx_->pix_fmt = AV_PIX_FMT_YUVA444P10LE;
    codecCtx_->time_base = kTimeBase;
    codecCtx_->sample_aspect_ratio = AVRational{1, 1};
    codecCtx_->profile = AV_PROFILE_PRORES_4444;
    if (formatCtx_->oformat->flags & AVFMT_GLOBALHEADER)
    {
        codecCtx_->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    // alpha_bits=16 is prores_ks's own default (confirmed via `ffmpeg -h encoder=prores_ks`) —
    // set explicitly anyway so this doesn't silently change if that default ever does (doc §7).
    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "alpha_bits", "16", 0);
    ret = avcodec_open2(codecCtx_, encoder, &opts);
    av_dict_free(&opts);
    if (ret < 0)
    {
        SetLastError("avcodec_open2 (prores_ks) failed: " + AvErrorToString(ret));
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }

    ret = avcodec_parameters_from_context(stream_->codecpar, codecCtx_);
    if (ret < 0)
    {
        SetLastError("avcodec_parameters_from_context failed: " + AvErrorToString(ret));
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }
    stream_->time_base = codecCtx_->time_base;

    if (!(formatCtx_->oformat->flags & AVFMT_NOFILE))
    {
        ret = avio_open(&formatCtx_->pb, utf8OutputPath.c_str(), AVIO_FLAG_WRITE);
        if (ret < 0)
        {
            SetLastError("avio_open failed: " + AvErrorToString(ret));
            ReleaseResources();
            return PE_ERROR_FILE_OPEN_FAILED;
        }
    }

    ret = avformat_write_header(formatCtx_, nullptr);
    if (ret < 0)
    {
        SetLastError("avformat_write_header failed: " + AvErrorToString(ret));
        ReleaseResources();
        return PE_ERROR_ENCODE_FAILED;
    }
    headerWritten_ = true;

    frame_ = av_frame_alloc();
    if (!frame_)
    {
        SetLastError("av_frame_alloc failed");
        ReleaseResources();
        return PE_ERROR_UNKNOWN;
    }
    frame_->format = codecCtx_->pix_fmt;
    frame_->width = width;
    frame_->height = height;
    ret = av_frame_get_buffer(frame_, 0);
    if (ret < 0)
    {
        SetLastError("av_frame_get_buffer failed: " + AvErrorToString(ret));
        ReleaseResources();
        return PE_ERROR_UNKNOWN;
    }

    packet_ = av_packet_alloc();
    if (!packet_)
    {
        SetLastError("av_packet_alloc failed");
        ReleaseResources();
        return PE_ERROR_UNKNOWN;
    }

    width_ = width;
    height_ = height;
    havePts_ = false;
    return PE_OK;
}

bool AlphaVideoEncoder::EncodeAndMux(AVFrame* frame, std::string& outError)
{
    int ret = avcodec_send_frame(codecCtx_, frame);
    if (ret < 0)
    {
        outError = "avcodec_send_frame failed: " + AvErrorToString(ret);
        return false;
    }

    while (true)
    {
        ret = avcodec_receive_packet(codecCtx_, packet_);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
        {
            break;
        }
        if (ret < 0)
        {
            outError = "avcodec_receive_packet failed: " + AvErrorToString(ret);
            return false;
        }

        av_packet_rescale_ts(packet_, codecCtx_->time_base, stream_->time_base);
        packet_->stream_index = stream_->index;

        // Takes ownership of packet_'s reference and blanks it (as if freshly allocated),
        // even on error — no separate av_packet_unref needed here either way.
        ret = av_interleaved_write_frame(formatCtx_, packet_);
        if (ret < 0)
        {
            outError = "av_interleaved_write_frame failed: " + AvErrorToString(ret);
            return false;
        }
    }
    return true;
}

int32_t AlphaVideoEncoder::PushFrame(const uint8_t* bgraData, int32_t strideBytes, double presentationSeconds)
{
    if (!formatCtx_ || !codecCtx_ || !frame_ || !packet_)
    {
        SetLastError("PE_EncodeAlphaVideoPushFrame: encoder is not open");
        return PE_ERROR_INVALID_HANDLE;
    }
    if (!bgraData || strideBytes <= 0)
    {
        SetLastError("PE_EncodeAlphaVideoPushFrame: invalid frame buffer");
        return PE_ERROR_INVALID_ARGUMENT;
    }
    if (havePts_ && !(presentationSeconds > lastPresentationSeconds_))
    {
        SetLastError("PE_EncodeAlphaVideoPushFrame: presentationSeconds must strictly increase between calls");
        return PE_ERROR_INVALID_ARGUMENT;
    }

    swsCtx_ = sws_getCachedContext(swsCtx_, width_, height_, AV_PIX_FMT_BGRA,
        width_, height_, AV_PIX_FMT_YUVA444P10LE, SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!swsCtx_)
    {
        SetLastError("sws_getCachedContext failed");
        return PE_ERROR_ENCODE_FAILED;
    }

    // The encoder may still hold a reference to frame_'s previous buffer (frame-threaded
    // encoding can keep several frames in flight) — never overwrite it in place.
    int ret = av_frame_make_writable(frame_);
    if (ret < 0)
    {
        SetLastError("av_frame_make_writable failed: " + AvErrorToString(ret));
        return PE_ERROR_ENCODE_FAILED;
    }

    const uint8_t* srcSlices[4] = {bgraData, nullptr, nullptr, nullptr};
    int srcStrides[4] = {strideBytes, 0, 0, 0};
    sws_scale(swsCtx_, srcSlices, srcStrides, 0, height_, frame_->data, frame_->linesize);

    frame_->pts = static_cast<int64_t>(std::llround(presentationSeconds * kTimeBase.den / kTimeBase.num));

    std::string error;
    if (!EncodeAndMux(frame_, error))
    {
        SetLastError(error);
        return PE_ERROR_ENCODE_FAILED;
    }

    lastGapWasLarge_ = havePts_ && (presentationSeconds - lastPresentationSeconds_) > kLargeGapThresholdSeconds;
    lastPresentationSeconds_ = presentationSeconds;
    havePts_ = true;
    return PE_OK;
}

int32_t AlphaVideoEncoder::Close()
{
    if (!formatCtx_ || !codecCtx_)
    {
        SetLastError("PE_EncodeAlphaVideoClose: encoder is not open");
        ReleaseResources();
        return PE_ERROR_INVALID_HANDLE;
    }

    std::string error;
    bool ok = true;

    // Workaround for a confirmed defect in this FFmpeg build's mov muxer: the LAST sample written
    // to a track, when its gap from the PREVIOUS sample exceeds a few hundred ms, silently never
    // makes it into the finished file's sample table — av_interleaved_write_frame/av_write_trailer
    // both still report success, but ffprobe (and any real player) only finds the samples before
    // it. Every OTHER sample survives fine regardless of ITS OWN gap size (verified empirically:
    // three samples one second apart each lose only the third, not the second) — only the sample
    // that ends up literally last is at risk. A freeze-frame hold-tail sample (doc §6/§8 — the
    // whole reason PushFrame allows non-uniform spacing at all) is exactly this "one big final
    // gap" shape, so without this, holdTailSeconds silently produces a container that ends at the
    // wrong (pre-hold) time. Fix: push one more copy of the same pixel data a small, ordinary gap
    // (1/30s) after the true last sample, purely so that sample is never the one at risk — an
    // imperceptible sub-frame extension of the encoded duration, not a second freeze-frame anyone
    // asked for. Skipped entirely for an ordinary (small, regular gap) sequence, so a normal
    // encode's sample count is unaffected.
    if (havePts_ && lastGapWasLarge_)
    {
        double closingSeconds = lastPresentationSeconds_ + kClosingSampleGapSeconds;
        frame_->pts = static_cast<int64_t>(std::llround(closingSeconds * kTimeBase.den / kTimeBase.num));
        ok = EncodeAndMux(frame_, error);
    }

    if (ok)
    {
        ok = EncodeAndMux(nullptr, error); // flush every buffered packet
    }
    if (ok && headerWritten_)
    {
        int ret = av_write_trailer(formatCtx_);
        if (ret < 0)
        {
            error = "av_write_trailer failed: " + AvErrorToString(ret);
            ok = false;
        }
    }
    if (!ok)
    {
        SetLastError(error);
    }

    ReleaseResources();
    return ok ? PE_OK : PE_ERROR_ENCODE_FAILED;
}

void AlphaVideoEncoder::Abort()
{
    ReleaseResources();
}

void AlphaVideoEncoder::ReleaseResources()
{
    if (packet_)
    {
        av_packet_free(&packet_);
    }
    if (frame_)
    {
        av_frame_free(&frame_);
    }
    if (swsCtx_)
    {
        sws_freeContext(swsCtx_);
        swsCtx_ = nullptr;
    }
    if (codecCtx_)
    {
        avcodec_free_context(&codecCtx_);
    }
    if (formatCtx_)
    {
        if (formatCtx_->pb && formatCtx_->oformat && !(formatCtx_->oformat->flags & AVFMT_NOFILE))
        {
            avio_closep(&formatCtx_->pb);
        }
        avformat_free_context(formatCtx_);
        formatCtx_ = nullptr;
    }
    stream_ = nullptr;
    width_ = 0;
    height_ = 0;
    headerWritten_ = false;
    havePts_ = false;
    lastPresentationSeconds_ = 0.0;
}
