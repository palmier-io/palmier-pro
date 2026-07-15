#pragma once

#include "TimelineSnapshot.h"

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

class MediaSource;
class RetimeStretcher;

// E4.5 mix slice (docs/audio-playback-v1.md §6). Sums every audible clip of a timeline snapshot
// into a Float32 / 48 kHz / stereo bus for a playhead sample range. Owns a per-clip audio decoder
// (a dedicated MediaSource per clip id, opened audio-only so its seeks never touch the video
// compositor's demuxer position — see MediaSource::OpenForAudio) whose 48 kHz cursor advances with
// playback and re-seeks on discontinuity.
//
// Per block (docs §6): for every non-muted "audio" track, for every clip covering the block's
// timeline frame, decode the covered source samples through the clip's per-clip resampler
// (MediaSource::ReadAudioStereo48k) — for a clip with speed != 1.0, routed through a per-clip
// RetimeStretcher (native/RetimeStretcher.h, wraps vendored signalsmith-stretch) first, so a
// `blockLen * speed`-sample source run becomes exactly `blockLen` pitch-preserved output samples
// instead of the speed==1 path's direct (pitch-shifting) linear resample — scale by gain(frame) =
// clip.volumeGain × dB-keyframe gain × fade envelope (§1 — gain sampled once per block, the "block
// cadence" the doc prescribes), and sum into the planar accumulator. A frame range with no covering
// audio clip stays silent. The planar accumulator is interleaved once at the end (§2). No pan (§1):
// a mono source duplicates to L/R, a stereo source passes L/R through.
//
// RenderRange is the offline path behind PE_TimelineRenderAudioRange (deterministic, no XAudio2
// device) and the same routine the live fill callback drives block-by-block once infra wires it in.
class AudioMixer
{
public:
    static constexpr uint32_t kMixSampleRate = 48000;
    static constexpr uint32_t kChannels = 2;
    static constexpr int32_t kBlockFrames = 960; // 20 ms @ 48 kHz — the doc §2 gain "block cadence"

    // Both declared here but defined (= default) in the .cpp, not inline: decoders_'s value type
    // (ClipDecoder) holds a unique_ptr<RetimeStretcher>, and RetimeStretcher is only forward-
    // declared in this header — an inline-default ctor/dtor would get instantiated at whatever
    // call site first constructs/destroys an AudioMixer (e.g. TimelineSession.cpp), which never
    // sees RetimeStretcher's complete type. Deferring to the .cpp (which includes
    // RetimeStretcher.h) is the standard pimpl-adjacent fix — same reason ~AudioMixer() was
    // already out-of-line before RetimeStretcher existed.
    AudioMixer();
    ~AudioMixer();
    AudioMixer(const AudioMixer&) = delete;
    AudioMixer& operator=(const AudioMixer&) = delete;

    // Fills outInterleavedStereo (sampleCount × 2 floats, caller-owned) with the mix for the range
    // starting at timeline frame `startFrame` and running `sampleCount` samples at 48 kHz. Silent
    // (zeroed) where no audible clip covers the range. Returns false only on an internal decode
    // setup error; a per-clip decode miss is treated as that clip's silence, never a hard failure.
    bool RenderRange(const TimelineSnapshot& snapshot, int64_t startFrame, int32_t sampleCount,
        float* outInterleavedStereo, std::string& outError);

private:
    // One clip's dedicated audio decoder; `failed` latches an open failure so we don't retry it
    // every block. Keyed by clip id so two clips over the same media keep independent cursors.
    // `retime`/`retimeSourceCursor` are only touched for a speed != 1.0 clip (§6 step 2) — the
    // stretcher owns STFT phase/history state that must stay continuous block-to-block, so it
    // lives here rather than in the per-block scratch below.
    struct ClipDecoder
    {
        std::unique_ptr<MediaSource> media;
        bool failed = false;
        std::unique_ptr<RetimeStretcher> retime;
        double retimeSourceCursor = 0.0;
        bool retimePrimed = false;
    };

    MediaSource* AcquireDecoder(const std::string& clipId, const std::string& mediaPath);
    RetimeStretcher* AcquireRetimeStretcher(ClipDecoder& entry);

    std::unordered_map<std::string, ClipDecoder> decoders_;

    // Per-clip decode scratch (reused across clips/blocks).
    std::vector<float> clipL_;
    std::vector<float> clipR_;
    // Per-clip retime output scratch (reused across clips/blocks) — only sized/written for a
    // speed != 1.0 clip; holds the stretcher's block-length, pitch-preserved output.
    std::vector<float> retimedL_;
    std::vector<float> retimedR_;
    // Planar mix accumulator for one block.
    std::vector<float> accumL_;
    std::vector<float> accumR_;
};
