#pragma once

#include "include/palmier_engine.h"

#include <wrl/client.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

struct IXAudio2;
struct IXAudio2MasteringVoice;
struct IXAudio2SourceVoice;
struct TimelineSnapshot;
class MediaSource;

// E4.5 scrub slice (docs/audio-playback-v1.md §9 "scrub", §5). A short (~50 ms), edge-faded
// windowed audio grab at a target timeline frame, played once through a lightweight one-shot
// voice that is entirely independent of AudioEngine's persistent playback voice — mirrors the
// Mac's own split between `AVPlayer` (main playback) and `ScrubAudioEngine`/`ScrubAudioOutput`
// (Sources/PalmierPro/Preview/ScrubAudioEngine.swift). Uses the SAME per-clip gain formula as the
// mix loop (Clip.volume × dB-keyframe gain × fade envelope, Track.muted honored, no pan — doc §1)
// — duplicated here rather than shared with AudioMixer.cpp (docs/audio-playback-v1.md §9 assigns
// AudioMixer.h/.cpp to a different, independently-developed slice) so this file stays a
// self-contained ownership unit.
class ScrubAudio
{
public:
    static constexpr int32_t kMixSampleRate = 48000;
    static constexpr int32_t kChannels = 2;
    static constexpr int32_t kGrainFrameCount = 2400; // 50 ms @ 48 kHz — mirrors grainFrameCount
    static constexpr int32_t kFadeFrameCount = 144;    // ~3 ms linear edge ramp — mirrors fadeFrameCount

    ScrubAudio();
    ~ScrubAudio();
    ScrubAudio(const ScrubAudio&) = delete;
    ScrubAudio& operator=(const ScrubAudio&) = delete;

    // Synchronously computes the gain-mixed, edge-faded grain for `frame`/`direction` against
    // `snapshot`, writing kGrainFrameCount × kChannels interleaved stereo floats into
    // outInterleavedStereo (caller-owned). Runs entirely on the calling thread — never touches
    // the XAudio2 device — used both by the offline golden hook (PE_TimelineRenderScrubGrain,
    // include/palmier_engine.h, implemented in PalmierEngine.cpp via
    // TimelineSession::RenderScrubGrain) and internally by Play()'s own worker thread. Never
    // fails on content grounds (doc §5): no audible clip at `frame`, or a clip whose decoder
    // fails to open, contributes silence rather than erroring.
    //
    // Retimed-clip parity exception (doc §5): for clip.speed != 1.0 the grain is plain
    // linear-interpolated from source at the retimed rate, so it is PITCH-SHIFTED (a 2x clip
    // scrubs an octave up, a 0.25x clip two octaves down) — unlike the pitch-preserving playback
    // mix (AudioMixer + RetimeStretcher) and unlike the Mac, whose ScrubAudioEngine reads
    // pre-composited timeline audio AVFoundation has already retimed pitch-preserved. This is a
    // sanctioned v1 simplification: signalsmith's priming latency (~60 ms) exceeds the 50 ms grain,
    // so routing a one-shot grain through the stretcher is impractical. The grain is a momentary
    // scrub-feedback transient, not sustained playback, so the shift is a tolerable divergence.
    void RenderGrain(const TimelineSnapshot& snapshot, int64_t frame, int32_t direction, float* outInterleavedStereo);

    // Latest-wins playback (doc §5): renders the grain on a dedicated worker thread and submits
    // it to the lightweight one-shot voice, cutting off whatever grain is still playing first. A
    // call arriving while a previous request is still pending replaces it outright — the
    // superseded request is dropped, never rendered. Returns immediately.
    void Play(std::shared_ptr<const TimelineSnapshot> snapshot, int64_t frame, int32_t direction);

    // Cuts off whatever is currently playing and drops any pending request.
    void Stop();

private:
    struct ClipDecoder
    {
        std::unique_ptr<MediaSource> media;
        bool failed = false;
    };

    MediaSource* AcquireDecoder(const std::string& clipId, const std::string& mediaPath);
    void WorkerLoop();
    void EnsureDevice();

    // Decode scratch — touched only from whichever thread is currently inside RenderGrain
    // (either the calling thread for a direct/offline call, or the worker thread for Play();
    // never both concurrently on one instance, mirroring MediaSource's own single-caller
    // contract). Keyed by clip id, same as AudioMixer's decoder map.
    std::unordered_map<std::string, ClipDecoder> decoders_;
    std::vector<float> clipL_;
    std::vector<float> clipR_;
    std::vector<float> accumL_;
    std::vector<float> accumR_;

    // Lightweight XAudio2 device + one-shot source voice, lazily created on the first Play() —
    // entirely separate from AudioEngine's persistent playback voice (doc §5: "the two voices
    // will audibly fight for the same output device," a caller-enforced contract, not a native
    // invariant). Falls back to a silent no-op, never a failure, on any device creation error
    // (doc §3.4-style no-device tolerance) or under PALMIERENGINE_FORCE_NULL_AUDIO.
    Microsoft::WRL::ComPtr<IXAudio2> xaudio2_;
    IXAudio2MasteringVoice* masteringVoice_ = nullptr;
    IXAudio2SourceVoice* sourceVoice_ = nullptr;
    bool deviceInitAttempted_ = false;
    bool devicePresent_ = false;

    std::thread worker_;
    std::mutex mutex_;
    std::condition_variable cv_;
    bool stopRequested_ = false;
    bool hasPending_ = false;
    std::shared_ptr<const TimelineSnapshot> pendingSnapshot_;
    int64_t pendingFrame_ = 0;
    int32_t pendingDirection_ = PE_SCRUB_AUDIO_FORWARD;
    std::vector<float> grainScratch_; // worker-thread-only
};
