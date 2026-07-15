#include "MediaSource.h"

#include <d3d11.h>

extern "C"
{
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>

namespace
{
    void ClassifyPixelFormat(AVPixelFormat fmt, int32_t& outClass, int32_t& outHasAlpha)
    {
        outClass = PE_PIXFMT_UNKNOWN;
        outHasAlpha = 0;
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(fmt);
        if (!desc)
        {
            return;
        }
        outHasAlpha = (desc->flags & AV_PIX_FMT_FLAG_ALPHA) ? 1 : 0;
        if (desc->flags & AV_PIX_FMT_FLAG_RGB)
        {
            outClass = PE_PIXFMT_RGB;
            return;
        }
        if (desc->nb_components < 2)
        {
            outClass = PE_PIXFMT_OTHER;
            return;
        }
        if (desc->log2_chroma_w == 1 && desc->log2_chroma_h == 1)
        {
            outClass = PE_PIXFMT_YUV420;
        }
        else if (desc->log2_chroma_w == 1 && desc->log2_chroma_h == 0)
        {
            outClass = PE_PIXFMT_YUV422;
        }
        else if (desc->log2_chroma_w == 0 && desc->log2_chroma_h == 0)
        {
            outClass = PE_PIXFMT_YUV444;
        }
        else
        {
            outClass = PE_PIXFMT_OTHER;
        }
    }

    std::string AvErrorToString(int errnum)
    {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(errnum, buf, sizeof(buf));
        return std::string(buf);
    }
}

MediaSource::~MediaSource()
{
    Close();
}

void MediaSource::Close()
{
    if (decodeSwsCtx_)
    {
        sws_freeContext(decodeSwsCtx_);
        decodeSwsCtx_ = nullptr;
    }
    if (videoCodecCtx_)
    {
        avcodec_free_context(&videoCodecCtx_);
    }
    if (audioCodecCtx_)
    {
        avcodec_free_context(&audioCodecCtx_);
    }
    if (formatCtx_)
    {
        avformat_close_input(&formatCtx_);
    }
    if (hwDeviceCtx_)
    {
        av_buffer_unref(&hwDeviceCtx_);
    }
    if (audioMixSwr_)
    {
        swr_free(&audioMixSwr_);
    }
    audioMixBufStart_ = kAudioCursorUnset;
    audioMixEof_ = false;
    audioMixBufL_.clear();
    audioMixBufR_.clear();
    hwPixFmt_ = AV_PIX_FMT_NONE;
    videoStreamIndex_ = -1;
    audioStreamIndex_ = -1;
    bgraBuffer_.clear();
    bgraBuffer_.shrink_to_fit();
    info_ = PE_MediaInfo{};
}

AVPixelFormat MediaSource::GetHwFormat(AVCodecContext* ctx, const AVPixelFormat* pixFmts)
{
    auto* self = static_cast<MediaSource*>(ctx->opaque);
    for (const AVPixelFormat* p = pixFmts; *p != AV_PIX_FMT_NONE; ++p)
    {
        if (*p == self->hwPixFmt_)
        {
            return *p;
        }
    }
    return pixFmts[0];
}

bool MediaSource::OpenVideoDecoderHardware(const AVCodec* decoder, AVCodecParameters* params, ID3D11Device* device, std::string& outError)
{
    bool supportsD3D11VA = false;
    for (int i = 0;; ++i)
    {
        const AVCodecHWConfig* config = avcodec_get_hw_config(decoder, i);
        if (!config)
        {
            break;
        }
        if (config->pix_fmt == AV_PIX_FMT_D3D11 && (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX))
        {
            supportsD3D11VA = true;
            break;
        }
    }
    if (!supportsD3D11VA)
    {
        outError = "decoder has no D3D11VA hwaccel config";
        return false;
    }

    AVBufferRef* hwCtx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
    if (!hwCtx)
    {
        outError = "av_hwdevice_ctx_alloc failed";
        return false;
    }
    auto* deviceCtx = reinterpret_cast<AVHWDeviceContext*>(hwCtx->data);
    auto* d3d11vaCtx = static_cast<AVD3D11VADeviceContext*>(deviceCtx->hwctx);
    device->AddRef();
    d3d11vaCtx->device = device;

    int ret = av_hwdevice_ctx_init(hwCtx);
    if (ret < 0)
    {
        outError = "av_hwdevice_ctx_init failed: " + AvErrorToString(ret);
        av_buffer_unref(&hwCtx);
        return false;
    }

    videoCodecCtx_ = avcodec_alloc_context3(decoder);
    avcodec_parameters_to_context(videoCodecCtx_, params);
    videoCodecCtx_->opaque = this;
    hwPixFmt_ = AV_PIX_FMT_D3D11;
    videoCodecCtx_->get_format = &MediaSource::GetHwFormat;
    videoCodecCtx_->hw_device_ctx = av_buffer_ref(hwCtx);

    ret = avcodec_open2(videoCodecCtx_, decoder, nullptr);
    if (ret < 0)
    {
        outError = "avcodec_open2 (D3D11VA) failed: " + AvErrorToString(ret);
        avcodec_free_context(&videoCodecCtx_);
        hwPixFmt_ = AV_PIX_FMT_NONE;
        av_buffer_unref(&hwCtx);
        return false;
    }

    hwDeviceCtx_ = hwCtx;
    return true;
}

bool MediaSource::OpenVideoDecoderSoftware(const AVCodec* decoder, AVCodecParameters* params, std::string& outError)
{
    videoCodecCtx_ = avcodec_alloc_context3(decoder);
    avcodec_parameters_to_context(videoCodecCtx_, params);
    int ret = avcodec_open2(videoCodecCtx_, decoder, nullptr);
    if (ret < 0)
    {
        outError = "avcodec_open2 (video) failed: " + AvErrorToString(ret);
        avcodec_free_context(&videoCodecCtx_);
        return false;
    }
    return true;
}

bool MediaSource::Open(const std::string& utf8Path, ID3D11Device* sharedDevice, bool deviceIsHardware, std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    int ret = avformat_open_input(&formatCtx_, utf8Path.c_str(), nullptr, nullptr);
    if (ret < 0)
    {
        outError = "avformat_open_input failed: " + AvErrorToString(ret);
        Close();
        return false;
    }

    ret = avformat_find_stream_info(formatCtx_, nullptr);
    if (ret < 0)
    {
        outError = "avformat_find_stream_info failed: " + AvErrorToString(ret);
        Close();
        return false;
    }

    videoStreamIndex_ = av_find_best_stream(formatCtx_, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    audioStreamIndex_ = av_find_best_stream(formatCtx_, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

    if (videoStreamIndex_ < 0 && audioStreamIndex_ < 0)
    {
        outError = "no video or audio stream found";
        Close();
        return false;
    }

    if (videoStreamIndex_ >= 0)
    {
        AVCodecParameters* params = formatCtx_->streams[videoStreamIndex_]->codecpar;
        const AVCodec* decoder = avcodec_find_decoder(params->codec_id);
        if (!decoder)
        {
            outError = "no decoder for video codec";
            Close();
            return false;
        }

        bool hwOk = false;
        if (sharedDevice && deviceIsHardware)
        {
            std::string hwError; // diagnostic only — falling back to software is not an error
            hwOk = OpenVideoDecoderHardware(decoder, params, sharedDevice, hwError);
        }
        if (!hwOk && !OpenVideoDecoderSoftware(decoder, params, outError))
        {
            Close();
            return false;
        }
    }

    if (audioStreamIndex_ >= 0)
    {
        AVCodecParameters* params = formatCtx_->streams[audioStreamIndex_]->codecpar;
        const AVCodec* decoder = avcodec_find_decoder(params->codec_id);
        if (!decoder)
        {
            outError = "no decoder for audio codec";
            Close();
            return false;
        }
        audioCodecCtx_ = avcodec_alloc_context3(decoder);
        avcodec_parameters_to_context(audioCodecCtx_, params);
        ret = avcodec_open2(audioCodecCtx_, decoder, nullptr);
        if (ret < 0)
        {
            outError = "avcodec_open2 (audio) failed: " + AvErrorToString(ret);
            Close();
            return false;
        }
    }

    FillInfo();
    return true;
}

bool MediaSource::OpenForAudio(const std::string& utf8Path, std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    int ret = avformat_open_input(&formatCtx_, utf8Path.c_str(), nullptr, nullptr);
    if (ret < 0)
    {
        outError = "avformat_open_input failed: " + AvErrorToString(ret);
        Close();
        return false;
    }
    ret = avformat_find_stream_info(formatCtx_, nullptr);
    if (ret < 0)
    {
        outError = "avformat_find_stream_info failed: " + AvErrorToString(ret);
        Close();
        return false;
    }

    audioStreamIndex_ = av_find_best_stream(formatCtx_, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (audioStreamIndex_ >= 0)
    {
        AVCodecParameters* params = formatCtx_->streams[audioStreamIndex_]->codecpar;
        const AVCodec* decoder = avcodec_find_decoder(params->codec_id);
        if (decoder)
        {
            audioCodecCtx_ = avcodec_alloc_context3(decoder);
            avcodec_parameters_to_context(audioCodecCtx_, params);
            if (avcodec_open2(audioCodecCtx_, decoder, nullptr) < 0)
            {
                avcodec_free_context(&audioCodecCtx_);
                audioStreamIndex_ = -1; // undecodable audio -> treat as silent, not a hard failure
            }
        }
        else
        {
            audioStreamIndex_ = -1;
        }
    }

    FillInfo();
    return true;
}

void MediaSource::FillInfo()
{
    info_ = PE_MediaInfo{};
    info_.hasVideo = videoStreamIndex_ >= 0 ? 1 : 0;
    info_.hasAudio = audioStreamIndex_ >= 0 ? 1 : 0;

    double durationSeconds = 0.0;
    if (formatCtx_->duration > 0)
    {
        durationSeconds = formatCtx_->duration / static_cast<double>(AV_TIME_BASE);
    }
    else if (videoStreamIndex_ >= 0)
    {
        AVStream* vs = formatCtx_->streams[videoStreamIndex_];
        if (vs->duration > 0)
        {
            durationSeconds = vs->duration * av_q2d(vs->time_base);
        }
    }
    else if (audioStreamIndex_ >= 0)
    {
        AVStream* as = formatCtx_->streams[audioStreamIndex_];
        if (as->duration > 0)
        {
            durationSeconds = as->duration * av_q2d(as->time_base);
        }
    }
    info_.durationSeconds = durationSeconds;

    if (videoStreamIndex_ >= 0)
    {
        AVStream* vs = formatCtx_->streams[videoStreamIndex_];
        AVRational fps = vs->avg_frame_rate;
        if (fps.num <= 0 || fps.den <= 0)
        {
            fps = vs->r_frame_rate;
        }
        if (fps.num <= 0 || fps.den <= 0)
        {
            fps = AVRational{30, 1};
        }
        info_.fpsNumerator = fps.num;
        info_.fpsDenominator = fps.den;
        info_.width = videoCodecCtx_->width;
        info_.height = videoCodecCtx_->height;
        ClassifyPixelFormat(videoCodecCtx_->pix_fmt, info_.pixelFormatClass, info_.hasAlpha);
    }

    if (audioStreamIndex_ >= 0)
    {
        info_.audioChannels = audioCodecCtx_->ch_layout.nb_channels;
        info_.audioSampleRate = audioCodecCtx_->sample_rate;
    }
}

bool MediaSource::SeekAndDecodeVideo(int64_t targetPts, bool approximate, const std::atomic<int32_t>* cancelFlag,
    AVFrame* outFrame, std::string& outError)
{
    int ret = av_seek_frame(formatCtx_, videoStreamIndex_, targetPts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0)
    {
        outError = "av_seek_frame failed: " + AvErrorToString(ret);
        return false;
    }
    avcodec_flush_buffers(videoCodecCtx_);

    AVPacket* pkt = av_packet_alloc();
    bool gotFrame = false;

    while (av_read_frame(formatCtx_, pkt) >= 0)
    {
        if (cancelFlag && cancelFlag->load(std::memory_order_relaxed) != 0)
        {
            av_packet_unref(pkt);
            av_packet_free(&pkt);
            outError = "cancelled";
            return false;
        }
        if (pkt->stream_index != videoStreamIndex_)
        {
            av_packet_unref(pkt);
            continue;
        }
        ret = avcodec_send_packet(videoCodecCtx_, pkt);
        av_packet_unref(pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN))
        {
            continue;
        }
        while (avcodec_receive_frame(videoCodecCtx_, outFrame) == 0)
        {
            gotFrame = true;
            if (approximate)
            {
                // First frame past the backward seek is the GOP's keyframe itself —
                // the "nearest preceding keyframe" tolerance-seek result.
                av_packet_free(&pkt);
                return true;
            }
            int64_t pts = outFrame->best_effort_timestamp != AV_NOPTS_VALUE ? outFrame->best_effort_timestamp : outFrame->pts;
            if (pts == AV_NOPTS_VALUE || pts >= targetPts)
            {
                av_packet_free(&pkt);
                return true;
            }
        }
    }

    // EOF: flush decoder for any frames still buffered.
    avcodec_send_packet(videoCodecCtx_, nullptr);
    while (avcodec_receive_frame(videoCodecCtx_, outFrame) == 0)
    {
        gotFrame = true;
    }

    av_packet_free(&pkt);
    if (!gotFrame)
    {
        outError = "no frame decoded (seek past end of stream?)";
    }
    return gotFrame;
}

bool MediaSource::MaterializeSystemMemoryFrame(AVFrame* decoded, AVFrame* transferScratch, AVFrame*& outUsable, std::string& outError)
{
    if (hwPixFmt_ == AV_PIX_FMT_NONE || decoded->format != hwPixFmt_)
    {
        outUsable = decoded;
        return true;
    }
    av_frame_unref(transferScratch);
    int ret = av_hwframe_transfer_data(transferScratch, decoded, 0);
    if (ret < 0)
    {
        outError = "av_hwframe_transfer_data failed: " + AvErrorToString(ret);
        return false;
    }
    outUsable = transferScratch;
    return true;
}

bool MediaSource::ConvertFrameToBgra(AVFrame* frame, int dstWidth, int dstHeight, uint8_t* dst, int dstStride,
    SwsContext*& swsCtx, std::string& outError)
{
    swsCtx = sws_getCachedContext(swsCtx, frame->width, frame->height, static_cast<AVPixelFormat>(frame->format),
        dstWidth, dstHeight, AV_PIX_FMT_BGRA, SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!swsCtx)
    {
        outError = "sws_getCachedContext failed";
        return false;
    }
    uint8_t* dstSlices[4] = {dst, nullptr, nullptr, nullptr};
    int dstStrides[4] = {dstStride, 0, 0, 0};
    sws_scale(swsCtx, frame->data, frame->linesize, 0, frame->height, dstSlices, dstStrides);
    return true;
}

bool MediaSource::DecodeFrameAt(double timelineSeconds, PE_FrameBuffer& outFrame, std::string& outError)
{
    return DecodeFrameAtEx(timelineSeconds, /*approximate*/ false, /*cancelFlag*/ nullptr, outFrame, outError);
}

bool MediaSource::DecodeFrameAtEx(double timelineSeconds, bool approximate, const std::atomic<int32_t>* cancelFlag,
    PE_FrameBuffer& outFrame, std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    if (videoStreamIndex_ < 0)
    {
        outError = "media has no video stream";
        return false;
    }

    AVStream* vs = formatCtx_->streams[videoStreamIndex_];
    double tb = av_q2d(vs->time_base);
    int64_t targetPts = static_cast<int64_t>(std::llround(timelineSeconds / tb));
    if (vs->start_time != AV_NOPTS_VALUE)
    {
        targetPts += vs->start_time;
    }

    AVFrame* frame = av_frame_alloc();
    AVFrame* transfer = av_frame_alloc();
    bool decoded = SeekAndDecodeVideo(targetPts, approximate, cancelFlag, frame, outError);
    if (!decoded)
    {
        av_frame_free(&frame);
        av_frame_free(&transfer);
        return false;
    }

    AVFrame* usable = nullptr;
    if (!MaterializeSystemMemoryFrame(frame, transfer, usable, outError))
    {
        av_frame_free(&frame);
        av_frame_free(&transfer);
        return false;
    }

    int width = usable->width;
    int height = usable->height;
    int stride = width * 4;
    bgraBuffer_.resize(static_cast<size_t>(stride) * height);

    bool converted = ConvertFrameToBgra(usable, width, height, bgraBuffer_.data(), stride, decodeSwsCtx_, outError);
    av_frame_free(&frame);
    av_frame_free(&transfer);
    if (!converted)
    {
        return false;
    }

    outFrame.data = bgraBuffer_.data();
    outFrame.width = width;
    outFrame.height = height;
    outFrame.strideBytes = stride;
    return true;
}

bool MediaSource::ExtractThumbnails(
    const double* times,
    int32_t count,
    int32_t width,
    int32_t height,
    PE_ThumbnailCallback callback,
    void* userCtx,
    const int32_t* cancelFlag,
    std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    if (videoStreamIndex_ < 0)
    {
        outError = "media has no video stream";
        return false;
    }
    if (count <= 0 || width <= 0 || height <= 0)
    {
        outError = "invalid thumbnail request (count/width/height must be positive)";
        return false;
    }

    const auto* cancel = reinterpret_cast<const std::atomic<int32_t>*>(cancelFlag);

    AVStream* vs = formatCtx_->streams[videoStreamIndex_];
    double tb = av_q2d(vs->time_base);

    SwsContext* thumbSws = nullptr;
    std::vector<uint8_t> thumbBuffer(static_cast<size_t>(width) * height * 4);
    int stride = width * 4;

    AVFrame* frame = av_frame_alloc();
    AVFrame* transfer = av_frame_alloc();
    bool ok = true;

    for (int32_t i = 0; i < count; ++i)
    {
        if (cancel && cancel->load(std::memory_order_relaxed) != 0)
        {
            break;
        }

        int64_t targetPts = static_cast<int64_t>(std::llround(times[i] / tb));
        if (vs->start_time != AV_NOPTS_VALUE)
        {
            targetPts += vs->start_time;
        }

        std::string frameError;
        av_frame_unref(frame);
        if (!SeekAndDecodeVideo(targetPts, /*approximate*/ false, cancel, frame, frameError))
        {
            // Skip an individual unreachable timestamp rather than failing the whole batch.
            continue;
        }

        AVFrame* usable = nullptr;
        if (!MaterializeSystemMemoryFrame(frame, transfer, usable, frameError))
        {
            // Same treatment as an unreachable timestamp — skip rather than fail the batch.
            continue;
        }

        if (!ConvertFrameToBgra(usable, width, height, thumbBuffer.data(), stride, thumbSws, outError))
        {
            ok = false;
            break;
        }

        callback(userCtx, i, times[i], thumbBuffer.data(), width, height, stride);
    }

    av_frame_free(&frame);
    av_frame_free(&transfer);
    if (thumbSws)
    {
        sws_freeContext(thumbSws);
    }
    return ok;
}

bool MediaSource::ExtractPeakEnvelope(
    double startSeconds,
    double durationSeconds,
    double peaksPerSecond,
    float* outBuffer,
    int32_t cap,
    int32_t& outCount,
    std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    outCount = 0;

    if (audioStreamIndex_ < 0)
    {
        outError = "media has no audio stream";
        return false;
    }
    if (durationSeconds <= 0 || peaksPerSecond <= 0 || cap <= 0 || !outBuffer)
    {
        outError = "invalid peak envelope request";
        return false;
    }

    AVStream* as = formatCtx_->streams[audioStreamIndex_];
    int sampleRate = audioCodecCtx_->sample_rate;
    int64_t hopSize = std::max<int64_t>(1, std::llround(sampleRate / peaksPerSecond));

    AVChannelLayout monoLayout = AV_CHANNEL_LAYOUT_MONO;
    SwrContext* swr = nullptr;
    int ret = swr_alloc_set_opts2(&swr, &monoLayout, AV_SAMPLE_FMT_FLT, sampleRate,
        &audioCodecCtx_->ch_layout, audioCodecCtx_->sample_fmt, sampleRate, 0, nullptr);
    if (ret < 0 || !swr)
    {
        outError = "swr_alloc_set_opts2 failed: " + AvErrorToString(ret);
        return false;
    }
    ret = swr_init(swr);
    if (ret < 0)
    {
        outError = "swr_init failed: " + AvErrorToString(ret);
        swr_free(&swr);
        return false;
    }

    double tb = av_q2d(as->time_base);
    int64_t seekTarget = static_cast<int64_t>(std::llround(startSeconds / tb));
    if (as->start_time != AV_NOPTS_VALUE)
    {
        seekTarget += as->start_time;
    }
    av_seek_frame(formatCtx_, audioStreamIndex_, seekTarget, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(audioCodecCtx_);

    const double windowEnd = startSeconds + durationSeconds;
    double cursorSec = startSeconds;
    float carryPeak = 0.0f;
    int64_t carryCount = 0;
    bool capReached = false;
    bool reachedWindowEnd = false;

    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    std::vector<float> outSamples;

    // Accumulates converted samples [begin, end) of outSamples into the hop-sized peak
    // windows; shared by the live packet loop, the EOF decoder drain, and the swr flush
    // below so all three feed the same carry state.
    auto accumulatePeaks = [&](int64_t begin, int64_t end) {
        for (int64_t s = std::max<int64_t>(0, begin); s < end; ++s)
        {
            float mag = std::fabs(outSamples[static_cast<size_t>(s)]);
            if (mag > carryPeak)
            {
                carryPeak = mag;
            }
            if (++carryCount >= hopSize)
            {
                if (outCount >= cap)
                {
                    capReached = true;
                    return;
                }
                outBuffer[outCount++] = carryPeak;
                carryPeak = 0.0f;
                carryCount = 0;
            }
        }
    };

    // Converts one decoded audio frame and folds its in-window samples into the peak
    // accumulator; used for both regularly-read frames and the EOF-drain frames below.
    auto processFrame = [&](AVFrame* f) {
        int64_t framePts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
        double frameStartSec = framePts != AV_NOPTS_VALUE ? framePts * tb : cursorSec;
        double frameEndSec = frameStartSec + static_cast<double>(f->nb_samples) / sampleRate;

        if (frameEndSec <= startSeconds)
        {
            cursorSec = frameEndSec;
            av_frame_unref(f);
            return;
        }
        if (frameStartSec >= windowEnd)
        {
            reachedWindowEnd = true;
            av_frame_unref(f);
            return;
        }

        int outCapacitySamples = swr_get_out_samples(swr, f->nb_samples);
        if (outCapacitySamples < 0)
        {
            outCapacitySamples = f->nb_samples;
        }
        outSamples.resize(static_cast<size_t>(outCapacitySamples));
        uint8_t* outPtr = reinterpret_cast<uint8_t*>(outSamples.data());
        int converted = swr_convert(swr, &outPtr, outCapacitySamples,
            const_cast<const uint8_t**>(f->data), f->nb_samples);
        av_frame_unref(f);
        if (converted <= 0)
        {
            return;
        }

        int64_t skipSamples = 0;
        if (frameStartSec < startSeconds)
        {
            skipSamples = static_cast<int64_t>(std::llround((startSeconds - frameStartSec) * sampleRate));
        }
        int64_t usableSamples = converted;
        double convertedEndSec = frameStartSec + static_cast<double>(converted) / sampleRate;
        if (convertedEndSec > windowEnd)
        {
            usableSamples = static_cast<int64_t>(std::llround((windowEnd - frameStartSec) * sampleRate));
        }

        accumulatePeaks(skipSamples, std::min<int64_t>(usableSamples, converted));
        cursorSec = frameStartSec + static_cast<double>(converted) / sampleRate;
    };

    while (!capReached && !reachedWindowEnd && av_read_frame(formatCtx_, pkt) >= 0)
    {
        if (pkt->stream_index != audioStreamIndex_)
        {
            av_packet_unref(pkt);
            continue;
        }
        if (avcodec_send_packet(audioCodecCtx_, pkt) < 0)
        {
            av_packet_unref(pkt);
            continue;
        }
        av_packet_unref(pkt);

        while (!capReached && !reachedWindowEnd && avcodec_receive_frame(audioCodecCtx_, frame) == 0)
        {
            processFrame(frame);
        }
    }

    // EOF: drain the decoder for any frame still buffered by its own delay — mirrors
    // SeekAndDecodeVideo's EOF flush. A codec/decoder that does hold back a trailing frame
    // until an explicit flush (unlike this build's AAC decoder, which empirically doesn't)
    // would otherwise have its tail silently dropped versus AVAssetReader's complete-stream
    // read on the Mac side.
    if (!capReached && !reachedWindowEnd)
    {
        avcodec_send_packet(audioCodecCtx_, nullptr);
        while (avcodec_receive_frame(audioCodecCtx_, frame) == 0)
        {
            processFrame(frame);
            if (capReached || reachedWindowEnd)
            {
                break;
            }
        }
    }

    // Flush any samples still buffered inside the resampler itself.
    if (!capReached && !reachedWindowEnd)
    {
        int flushCapacity = swr_get_out_samples(swr, 0);
        if (flushCapacity > 0)
        {
            outSamples.resize(static_cast<size_t>(flushCapacity));
            uint8_t* outPtr = reinterpret_cast<uint8_t*>(outSamples.data());
            int converted = swr_convert(swr, &outPtr, flushCapacity, nullptr, 0);
            if (converted > 0)
            {
                accumulatePeaks(0, converted);
            }
        }
    }

    if (!capReached && carryCount > 0 && outCount < cap)
    {
        outBuffer[outCount++] = carryPeak;
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    swr_free(&swr);
    return true;
}

bool MediaSource::EnsureAudioMixSwr(std::string& outError)
{
    if (audioMixSwr_)
    {
        return true;
    }
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    int ret = swr_alloc_set_opts2(&audioMixSwr_, &stereo, AV_SAMPLE_FMT_FLTP, kMixSampleRate,
        &audioCodecCtx_->ch_layout, audioCodecCtx_->sample_fmt, audioCodecCtx_->sample_rate, 0, nullptr);
    if (ret < 0 || !audioMixSwr_)
    {
        outError = "swr_alloc_set_opts2 (mix) failed: " + AvErrorToString(ret);
        return false;
    }
    // "Mono source: duplicate to L/R" at unity (docs/audio-playback-v1.md §1) — override swr's
    // default power-preserving mono->stereo rematrix (which spreads at 1/sqrt(2) per channel) so a
    // mono clip lands at the same per-channel level the doc (and the Mac) specify. Stereo/other
    // layouts keep swr's default matrix (stereo->stereo is identity; §1 says stereo passes through).
    if (audioCodecCtx_->ch_layout.nb_channels == 1)
    {
        const double duplicate[2] = { 1.0, 1.0 }; // L = mono, R = mono; matrix[out*stride + in], stride 1
        swr_set_matrix(audioMixSwr_, duplicate, 1);
    }
    ret = swr_init(audioMixSwr_);
    if (ret < 0)
    {
        outError = "swr_init (mix) failed: " + AvErrorToString(ret);
        swr_free(&audioMixSwr_);
        return false;
    }
    return true;
}

void MediaSource::SeekAudioMix(int64_t startSample)
{
    AVStream* as = formatCtx_->streams[audioStreamIndex_];
    double tb = av_q2d(as->time_base);
    double sourceSeconds = static_cast<double>(startSample) / kMixSampleRate;
    int64_t targetPts = static_cast<int64_t>(std::llround(sourceSeconds / tb)) + audioMixStartTimePts_;
    av_seek_frame(formatCtx_, audioStreamIndex_, targetPts, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(audioCodecCtx_);
    // A fresh resampler after every seek keeps the anchor exact — the first resampled sample lines
    // up with the first decoded frame's PTS with no carried-over phase from the pre-seek position.
    if (audioMixSwr_)
    {
        swr_free(&audioMixSwr_);
    }
    audioMixBufL_.clear();
    audioMixBufR_.clear();
    audioMixBufStart_ = kAudioCursorUnset;
    audioMixEof_ = false;
}

bool MediaSource::DecodeAudioMixUntil(int64_t coverEnd, std::string& outError)
{
    AVStream* as = formatCtx_->streams[audioStreamIndex_];
    double tb = av_q2d(as->time_base);

    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    std::vector<float> tmpL;
    std::vector<float> tmpR;

    auto appendFrame = [&](AVFrame* f) {
        if (audioMixBufStart_ == kAudioCursorUnset)
        {
            int64_t framePts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
            double frameSec = framePts != AV_NOPTS_VALUE ? (framePts - audioMixStartTimePts_) * tb : 0.0;
            audioMixBufStart_ = static_cast<int64_t>(std::llround(frameSec * kMixSampleRate));
        }
        int outCapacity = swr_get_out_samples(audioMixSwr_, f->nb_samples);
        if (outCapacity <= 0)
        {
            return;
        }
        tmpL.resize(static_cast<size_t>(outCapacity));
        tmpR.resize(static_cast<size_t>(outCapacity));
        uint8_t* planes[2] = { reinterpret_cast<uint8_t*>(tmpL.data()), reinterpret_cast<uint8_t*>(tmpR.data()) };
        int converted = swr_convert(audioMixSwr_, planes, outCapacity,
            const_cast<const uint8_t**>(f->data), f->nb_samples);
        if (converted <= 0)
        {
            return;
        }
        audioMixBufL_.insert(audioMixBufL_.end(), tmpL.begin(), tmpL.begin() + converted);
        audioMixBufR_.insert(audioMixBufR_.end(), tmpR.begin(), tmpR.begin() + converted);
    };

    bool covered = false;
    while (!audioMixEof_)
    {
        if (audioMixBufStart_ != kAudioCursorUnset &&
            audioMixBufStart_ + static_cast<int64_t>(audioMixBufL_.size()) >= coverEnd)
        {
            covered = true;
            break;
        }
        int ret = av_read_frame(formatCtx_, pkt);
        if (ret < 0)
        {
            // Physical EOF: drain the decoder, then flush the resampler's tail.
            avcodec_send_packet(audioCodecCtx_, nullptr);
            while (avcodec_receive_frame(audioCodecCtx_, frame) == 0)
            {
                appendFrame(frame);
                av_frame_unref(frame);
            }
            int flushCap = swr_get_out_samples(audioMixSwr_, 0);
            if (flushCap > 0)
            {
                tmpL.resize(static_cast<size_t>(flushCap));
                tmpR.resize(static_cast<size_t>(flushCap));
                uint8_t* planes[2] = { reinterpret_cast<uint8_t*>(tmpL.data()), reinterpret_cast<uint8_t*>(tmpR.data()) };
                int converted = swr_convert(audioMixSwr_, planes, flushCap, nullptr, 0);
                if (converted > 0 && audioMixBufStart_ != kAudioCursorUnset)
                {
                    audioMixBufL_.insert(audioMixBufL_.end(), tmpL.begin(), tmpL.begin() + converted);
                    audioMixBufR_.insert(audioMixBufR_.end(), tmpR.begin(), tmpR.begin() + converted);
                }
            }
            audioMixEof_ = true;
            break;
        }
        if (pkt->stream_index != audioStreamIndex_)
        {
            av_packet_unref(pkt);
            continue;
        }
        if (avcodec_send_packet(audioCodecCtx_, pkt) < 0)
        {
            av_packet_unref(pkt);
            continue;
        }
        av_packet_unref(pkt);
        while (avcodec_receive_frame(audioCodecCtx_, frame) == 0)
        {
            appendFrame(frame);
            av_frame_unref(frame);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    (void)covered;
    (void)outError;
    return true;
}

bool MediaSource::ReadAudioStereo48k(int64_t startSample, int32_t count, float* outL, float* outR, std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    if (count <= 0)
    {
        return true;
    }
    if (audioStreamIndex_ < 0)
    {
        std::memset(outL, 0, static_cast<size_t>(count) * sizeof(float));
        std::memset(outR, 0, static_cast<size_t>(count) * sizeof(float));
        return true;
    }

    AVStream* as = formatCtx_->streams[audioStreamIndex_];
    audioMixStartTimePts_ = as->start_time != AV_NOPTS_VALUE ? as->start_time : 0;

    const int64_t coverEnd = startSample + count;
    // Forward reads within (or just past) the buffered run stream on; a backward jump or a large
    // forward gap re-seeks. One second of slack absorbs block-to-block cursor jitter without a seek.
    constexpr int64_t kMaxForwardGap = kMixSampleRate;
    const int64_t buffered = static_cast<int64_t>(audioMixBufL_.size());
    const bool needSeek = audioMixBufStart_ == kAudioCursorUnset ||
        startSample < audioMixBufStart_ ||
        startSample > audioMixBufStart_ + buffered + kMaxForwardGap;

    if (needSeek)
    {
        SeekAudioMix(startSample);
    }
    else if (startSample > audioMixBufStart_)
    {
        // Drop the consumed head so the buffer can't grow without bound during playback.
        int64_t drop = std::min<int64_t>(startSample - audioMixBufStart_, buffered);
        audioMixBufL_.erase(audioMixBufL_.begin(), audioMixBufL_.begin() + drop);
        audioMixBufR_.erase(audioMixBufR_.begin(), audioMixBufR_.begin() + drop);
        audioMixBufStart_ += drop;
    }

    if (!EnsureAudioMixSwr(outError))
    {
        return false;
    }
    if (!DecodeAudioMixUntil(coverEnd, outError))
    {
        return false;
    }

    for (int32_t i = 0; i < count; ++i)
    {
        int64_t idx = (audioMixBufStart_ == kAudioCursorUnset) ? -1 : (startSample + i - audioMixBufStart_);
        if (idx >= 0 && idx < static_cast<int64_t>(audioMixBufL_.size()))
        {
            outL[i] = audioMixBufL_[static_cast<size_t>(idx)];
            outR[i] = audioMixBufR_[static_cast<size_t>(idx)];
        }
        else
        {
            outL[i] = 0.0f;
            outR[i] = 0.0f;
        }
    }
    return true;
}
