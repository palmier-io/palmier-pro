#pragma once

#include "include/palmier_engine.h"

#include <cstdint>
#include <string>

extern "C"
{
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
}

class EngineSession;

// Streaming ProRes 4444 (yuva444p10le) .mov encoder behind PE_EncodeAlphaVideo{Open,
// PushFrame,Close,Abort} — see docs/lottie-bake-v1.md §7/§8 and include/palmier_engine.h for
// the exact per-call contract this mirrors 1:1. One instance per PE_AlphaEncoderHandle.
//
// Unlike MediaSource/TimelineSession, EngineSession does not own this object's lifetime —
// PE_EncodeAlphaVideoPushFrame/Close/Abort take no session, so there is no per-session map to
// register it in. Validity is instead tracked by a small process-wide registry (see Resolve,
// mirroring TimelineRegistry's handle-only validation for the identical reason: reject a
// stale/closed/forged handle rather than blindly dereferencing it). owner_ is kept only to
// forward a diagnostic string to EngineSession::SetLastError on failure — the same "best
// effort, may be stale for a handle-only call" convention TimelineSession already established
// (see its owner_->SetLastError usage) — this class has no other dependency on session
// lifetime, and outliving or closing the session has no effect on an open encoder.
//
// Not thread-safe on a single instance — callers serialize PushFrame calls (same discipline
// as every other native encode/decode object in this codebase, e.g. MediaSource).
class AlphaVideoEncoder
{
public:
    explicit AlphaVideoEncoder(EngineSession* owner);
    ~AlphaVideoEncoder();

    AlphaVideoEncoder(const AlphaVideoEncoder&) = delete;
    AlphaVideoEncoder& operator=(const AlphaVideoEncoder&) = delete;

    // width/height must be positive and EVEN (ProRes 4:4:4:4 requirement) — PE_ERROR_INVALID_ARGUMENT
    // otherwise. PE_ERROR_FILE_OPEN_FAILED if utf8OutputPath can't be opened for write;
    // PE_ERROR_ENCODE_FAILED if avformat/avcodec setup itself fails. No temp-file/atomic-rename
    // dance of its own — see PE_EncodeAlphaVideoOpen's doc comment.
    int32_t Open(const std::string& utf8OutputPath, int32_t width, int32_t height);

    // bgraData is premultiplied BGRA32, `width x height` pixels at `strideBytes` — identical
    // contract to PE_EncodeAlphaVideoPushFrame (palmier_engine.h). presentationSeconds must be
    // strictly greater than the previous call's value (PE_ERROR_INVALID_ARGUMENT otherwise);
    // need not be evenly spaced — a large gap encodes a hold as one extra sample, not repeated
    // frames (the freeze-frame tail mechanism, doc §6/§8). Copies bgraData before returning.
    int32_t PushFrame(const uint8_t* bgraData, int32_t strideBytes, double presentationSeconds);

    // Flushes buffered packets and finalizes the container (moov atom) — the output file is
    // only complete/playable once this returns PE_OK. Frees every native FFmpeg resource
    // regardless of the returned status; the instance must not be used again after this call.
    int32_t Close();

    // Cancellation path: discards buffered/unflushed packets and frees native FFmpeg resources
    // WITHOUT writing the trailer — output left incomplete/unplayable if anything was written.
    // Does not touch the filesystem beyond whatever closing the OS file handle itself does.
    // Always succeeds; the instance must not be used again after this call.
    void Abort();

    // Returns candidate back if it's a currently-live, registered instance, else nullptr —
    // mirrors TimelineRegistry::Resolve (see its header) for this ABI's handle-only entry
    // points (PushFrame/Close/Abort take no session to validate a handle through).
    static AlphaVideoEncoder* Resolve(AlphaVideoEncoder* candidate);

private:
    EngineSession* owner_;

    AVFormatContext* formatCtx_ = nullptr;
    AVCodecContext* codecCtx_ = nullptr;
    AVStream* stream_ = nullptr;
    SwsContext* swsCtx_ = nullptr;
    AVFrame* frame_ = nullptr;
    AVPacket* packet_ = nullptr;

    int32_t width_ = 0;
    int32_t height_ = 0;
    bool headerWritten_ = false;
    bool havePts_ = false;
    double lastPresentationSeconds_ = 0.0;
    // Set by PushFrame when the gap from the PREVIOUS sample exceeded kLargeGapThresholdSeconds —
    // i.e. true exactly when the most-recently-pushed sample (a freeze-frame hold-tail, most
    // commonly) is at risk of Close()'s mov-muxer workaround being needed. See Close()'s own
    // comment for why this exists at all.
    bool lastGapWasLarge_ = false;

    // QuickTime's own canonical movie timescale — divides evenly into every frame rate this
    // codebase supports (24/25/30/50/60 -> 3750/3600/3000/1800/1500 ticks/frame) while staying
    // exactly the "shorter timebase" FFmpeg's own mov muxer asks for (see AlphaVideoEncoder.cpp's
    // Open()) — a much higher timebase (e.g. 1/600000) reproducibly makes the mov muxer silently
    // drop every packet after the first whenever two consecutive PushFrame calls are more than a
    // few hundred ms apart (verified empirically: the freeze-frame hold-tail sample, always a
    // large gap by construction, never made it into the container at 1/600000, despite every
    // avcodec_send_frame/receive_packet/av_interleaved_write_frame call along the way reporting
    // success — an FFmpeg mov-muxer-internal issue, not anything-caller-observable failing).
    static constexpr AVRational kTimeBase = {1, 90000};

    // See Close()'s own comment: the gap size above which a pushed sample is treated as "might
    // become the file's vulnerable last sample" (comfortably above any real single-frame interval
    // down to 5fps [0.2s], comfortably below the smallest gap this mov-muxer defect was confirmed
    // to actually trigger on [0.5s]) — and the small, ordinary-sized gap used for the closing
    // sample Close() pushes to work around it.
    static constexpr double kLargeGapThresholdSeconds = 0.25;
    static constexpr double kClosingSampleGapSeconds = 1.0 / 30.0;

    // Sends one frame (or nullptr to flush at Close) through the encoder and muxes every
    // packet it yields; shared by PushFrame and Close's final flush.
    bool EncodeAndMux(AVFrame* frame, std::string& outError);

    // Idempotent — releases every FFmpeg resource this instance holds and resets back to a
    // fresh-constructed state. Does NOT write a trailer; callers that need one (Close) do so
    // before calling this.
    void ReleaseResources();

    void SetLastError(const std::string& message);
};
