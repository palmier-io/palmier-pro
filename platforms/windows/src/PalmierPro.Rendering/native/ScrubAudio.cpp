#include "ScrubAudio.h"

#include "MediaSource.h"
#include "TimelineSnapshot.h"

#include <xaudio2.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace
{
    // PalmierPro.Core.Models.VolumeScale (Timeline.cs:33) clamp bounds — duplicated from
    // AudioMixer.cpp's identical anonymous-namespace helpers (see ScrubAudio.h's header comment
    // for why this file doesn't share code with AudioMixer.cpp).
    constexpr double kVolumeScaleFloorDb = -60.0;
    constexpr double kVolumeScaleCeilingDb = 15.0;

    double LinearFromDb(double db)
    {
        if (db <= kVolumeScaleFloorDb)
        {
            return 0.0;
        }
        return std::pow(10.0, std::min(db, kVolumeScaleCeilingDb) / 20.0);
    }

    // Port of Clip.FadeMultiplier (Timeline.cs:342), sampled at a single timeline frame — a scrub
    // grain uses the same one-gain-sample-per-render cadence AudioMixer uses per mix block (doc §6).
    double FadeMultiplier(const SnapshotClip& c, int64_t timelineFrame)
    {
        int64_t rel = timelineFrame - c.startFrame;
        if (rel < 0 || rel > c.durationFrames)
        {
            return 0.0;
        }
        double inMul = 1.0;
        if (c.fadeInFrames > 0)
        {
            double t = std::min(1.0, static_cast<double>(rel) / static_cast<double>(c.fadeInFrames));
            inMul = c.fadeInInterpolation == SnapshotInterpolation::Smooth ? SmoothStep(t) : t;
        }
        int64_t outRem = c.durationFrames - rel;
        double outMul = 1.0;
        if (c.fadeOutFrames > 0)
        {
            double t = std::min(1.0, static_cast<double>(outRem) / static_cast<double>(c.fadeOutFrames));
            outMul = c.fadeOutInterpolation == SnapshotInterpolation::Smooth ? SmoothStep(t) : t;
        }
        return std::min(inMul, outMul);
    }

    double DbKeyframeGain(const SnapshotClip& c, int64_t timelineFrame)
    {
        if (c.volumeKeyframes.empty())
        {
            return 1.0;
        }
        double db = SampleKeyframeTrack(c.volumeKeyframes, timelineFrame - c.startFrame, 0.0, InterpolateDouble);
        return LinearFromDb(db);
    }

    // Port of ScrubAudioEngine.edgeGain (ScrubAudioEngine.swift:286-289) — a ~3 ms linear ramp at
    // both ends of the grain so the windowed grab never clicks. Symmetric under
    // index -> (frameCount - 1 - index), which is exactly what makes ScrubAudio::Play's direction
    // reversal (below) equivalent to reversing an already-faded forward grain.
    float EdgeGain(int32_t index, int32_t frameCount, int32_t fadeFrameCount)
    {
        float fadeIn = std::min(1.0f, static_cast<float>(index + 1) / static_cast<float>(fadeFrameCount));
        float fadeOut = std::min(1.0f, static_cast<float>(frameCount - index) / static_cast<float>(fadeFrameCount));
        return std::min(fadeIn, fadeOut);
    }

    // Mirrors AudioEngine.cpp's ForceNullAudioRequested — CI can force ScrubAudio's independent
    // device onto the same null-device fallback path deterministically.
    bool ForceNullAudioRequested()
    {
        char* value = nullptr;
        size_t len = 0;
        if (_dupenv_s(&value, &len, "PALMIERENGINE_FORCE_NULL_AUDIO") != 0 || !value)
        {
            return false;
        }
        bool forced = len > 0 && value[0] != '0';
        free(value);
        return forced;
    }
}

ScrubAudio::ScrubAudio() = default;

ScrubAudio::~ScrubAudio()
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopRequested_ = true;
        hasPending_ = false;
        pendingSnapshot_.reset();
    }
    cv_.notify_all();
    if (worker_.joinable())
    {
        worker_.join();
    }

    if (sourceVoice_)
    {
        sourceVoice_->DestroyVoice();
        sourceVoice_ = nullptr;
    }
    if (masteringVoice_)
    {
        masteringVoice_->DestroyVoice();
        masteringVoice_ = nullptr;
    }
    xaudio2_.Reset();
}

MediaSource* ScrubAudio::AcquireDecoder(const std::string& clipId, const std::string& mediaPath)
{
    auto it = decoders_.find(clipId);
    if (it != decoders_.end())
    {
        return it->second.failed ? nullptr : it->second.media.get();
    }

    ClipDecoder entry;
    entry.media = std::make_unique<MediaSource>();
    std::string openError;
    if (!entry.media->OpenForAudio(mediaPath, openError))
    {
        entry.media.reset();
        entry.failed = true;
        decoders_.emplace(clipId, std::move(entry));
        return nullptr;
    }
    MediaSource* raw = entry.media.get();
    decoders_.emplace(clipId, std::move(entry));
    return raw;
}

void ScrubAudio::RenderGrain(const TimelineSnapshot& snapshot, int64_t frame, int32_t direction, float* outInterleavedStereo)
{
    constexpr int32_t N = kGrainFrameCount;
    constexpr int64_t halfGrain = N / 2;

    const double fps = snapshot.Fps();
    const double samplesPerFrame = static_cast<double>(kMixSampleRate) / fps;
    const int64_t targetSample = static_cast<int64_t>(std::llround(static_cast<double>(frame) * samplesPerFrame));
    const int64_t windowStart = targetSample - halfGrain; // may be negative near timeline start

    accumL_.assign(static_cast<size_t>(N), 0.0f);
    accumR_.assign(static_cast<size_t>(N), 0.0f);

    for (const SnapshotTrack& track : snapshot.tracks)
    {
        if (track.type != SnapshotTrackType::Audio || track.muted)
        {
            continue; // a muted track is skipped whole, same as the mix loop (doc §6.1)
        }

        const SnapshotClip* clip = nullptr;
        for (const SnapshotClip& c : track.clips)
        {
            if (c.ContainsFrame(frame))
            {
                clip = &c;
                break; // clips are ordered and non-overlapping within a track
            }
        }
        if (!clip)
        {
            continue;
        }

        // audio.denoise travels in clip.effects but is a Phase-3 wet/dry render — bypassed here
        // exactly like the mix loop (doc §1).

        MediaSource* decoder = AcquireDecoder(clip->id, clip->mediaPath);
        if (!decoder)
        {
            continue;
        }

        const double gain = clip->volumeGain * DbKeyframeGain(*clip, frame) * FadeMultiplier(*clip, frame);
        if (gain == 0.0)
        {
            continue;
        }

        const double trimStartSample = static_cast<double>(clip->trimStartFrame) * samplesPerFrame;
        const double clipStartSample = static_cast<double>(clip->startFrame) * samplesPerFrame;
        // clip->speed maps timeline->source at the retimed rate, then the window is plain
        // linear-interpolated: for speed != 1.0 the grain is pitch-shifted, a sanctioned v1 parity
        // exception (the stretcher's ~60 ms priming exceeds a 50 ms grain) — see ScrubAudio.h / doc §5.
        auto srcPosExact = [&](int64_t absoluteMixSample) {
            return trimStartSample + (static_cast<double>(absoluteMixSample) - clipStartSample) * clip->speed;
        };

        const double srcMin = srcPosExact(windowStart);
        const double srcMax = srcPosExact(windowStart + N - 1);
        const int64_t srcStartInt = static_cast<int64_t>(std::floor(std::min(srcMin, srcMax)));
        const int64_t srcEndInt = static_cast<int64_t>(std::floor(std::max(srcMin, srcMax))) + 2;
        const int32_t decodeCount = static_cast<int32_t>(std::max<int64_t>(1, srcEndInt - srcStartInt));

        clipL_.resize(static_cast<size_t>(decodeCount));
        clipR_.resize(static_cast<size_t>(decodeCount));
        std::string decodeError;
        if (!decoder->ReadAudioStereo48k(srcStartInt, decodeCount, clipL_.data(), clipR_.data(), decodeError))
        {
            continue; // decode setup miss for this clip -> its silence, not a whole-grain failure
        }

        for (int32_t j = 0; j < N; ++j)
        {
            const double pos = srcPosExact(windowStart + j) - static_cast<double>(srcStartInt);
            const int32_t i0 = static_cast<int32_t>(std::floor(pos));
            if (i0 < 0 || i0 >= decodeCount)
            {
                continue;
            }
            const double frac = pos - i0;
            float l = clipL_[static_cast<size_t>(i0)];
            float r = clipR_[static_cast<size_t>(i0)];
            if (i0 + 1 < decodeCount)
            {
                l = static_cast<float>(l + (clipL_[static_cast<size_t>(i0 + 1)] - l) * frac);
                r = static_cast<float>(r + (clipR_[static_cast<size_t>(i0 + 1)] - r) * frac);
            }

            // Forward keeps time order (source offset j lands at output slot j); reverse mirrors
            // the window so a backward step audibly plays it in reverse — mirrors
            // ScrubAudioEngine.makeGrain's forward/reverse source-sample selection exactly (doc §5).
            const int32_t outIndex = (direction == PE_SCRUB_AUDIO_REVERSE) ? (N - 1 - j) : j;
            accumL_[static_cast<size_t>(outIndex)] += static_cast<float>(gain * l);
            accumR_[static_cast<size_t>(outIndex)] += static_cast<float>(gain * r);
        }
    }

    for (int32_t j = 0; j < N; ++j)
    {
        const float edge = EdgeGain(j, N, kFadeFrameCount);
        outInterleavedStereo[j * 2 + 0] = std::clamp(accumL_[static_cast<size_t>(j)] * edge, -1.0f, 1.0f);
        outInterleavedStereo[j * 2 + 1] = std::clamp(accumR_[static_cast<size_t>(j)] * edge, -1.0f, 1.0f);
    }
}

void ScrubAudio::EnsureDevice()
{
    if (deviceInitAttempted_)
    {
        return;
    }
    deviceInitAttempted_ = true;

    // Any failure below leaves devicePresent_ false and Play() becomes a silent no-op — mirrors
    // AudioEngine's own no-device tolerance (doc §3.4); never surfaces as a failure.
    if (ForceNullAudioRequested())
    {
        return;
    }
    if (FAILED(XAudio2Create(xaudio2_.ReleaseAndGetAddressOf(), 0, XAUDIO2_DEFAULT_PROCESSOR)))
    {
        return;
    }
    if (FAILED(xaudio2_->CreateMasteringVoice(&masteringVoice_, 0, 0)))
    {
        xaudio2_.Reset();
        return;
    }

    WAVEFORMATEX wfx{};
    wfx.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    wfx.nChannels = static_cast<WORD>(kChannels);
    wfx.nSamplesPerSec = kMixSampleRate;
    wfx.wBitsPerSample = 32;
    wfx.nBlockAlign = static_cast<WORD>(kChannels * sizeof(float));
    wfx.nAvgBytesPerSec = kMixSampleRate * wfx.nBlockAlign;
    wfx.cbSize = 0;

    if (FAILED(xaudio2_->CreateSourceVoice(&sourceVoice_, &wfx)))
    {
        masteringVoice_->DestroyVoice();
        masteringVoice_ = nullptr;
        xaudio2_.Reset();
        return;
    }

    devicePresent_ = true;
}

void ScrubAudio::WorkerLoop()
{
    for (;;)
    {
        std::shared_ptr<const TimelineSnapshot> snapshot;
        int64_t frame = 0;
        int32_t direction = PE_SCRUB_AUDIO_FORWARD;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [&] { return stopRequested_ || hasPending_; });
            if (stopRequested_)
            {
                return;
            }
            snapshot = std::move(pendingSnapshot_);
            pendingSnapshot_.reset();
            frame = pendingFrame_;
            direction = pendingDirection_;
            hasPending_ = false;
        }
        if (!snapshot)
        {
            continue;
        }

        // Cut off whatever's still playing BEFORE reusing grainScratch_ — XAudio2's
        // SubmitSourceBuffer references the memory directly (no internal copy), so the previous
        // grain's buffer must be released (Stop + Flush) before this call overwrites it.
        EnsureDevice();
        if (devicePresent_)
        {
            sourceVoice_->Stop(0);
            sourceVoice_->FlushSourceBuffers();
        }

        grainScratch_.resize(static_cast<size_t>(kGrainFrameCount) * kChannels);
        RenderGrain(*snapshot, frame, direction, grainScratch_.data());

        if (devicePresent_)
        {
            XAUDIO2_BUFFER xb{};
            xb.AudioBytes = static_cast<UINT32>(kGrainFrameCount) * kChannels * sizeof(float);
            xb.pAudioData = reinterpret_cast<const BYTE*>(grainScratch_.data());
            xb.Flags = XAUDIO2_END_OF_STREAM;
            sourceVoice_->SubmitSourceBuffer(&xb);
            sourceVoice_->Start(0);
        }
    }
}

void ScrubAudio::Play(std::shared_ptr<const TimelineSnapshot> snapshot, int64_t frame, int32_t direction)
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopRequested_)
        {
            return; // torn down (destructor already joining the worker) — drop silently
        }
        pendingSnapshot_ = std::move(snapshot);
        pendingFrame_ = frame;
        pendingDirection_ = direction;
        hasPending_ = true;
        if (!worker_.joinable())
        {
            worker_ = std::thread(&ScrubAudio::WorkerLoop, this);
        }
    }
    cv_.notify_one();
}

void ScrubAudio::Stop()
{
    std::lock_guard<std::mutex> lock(mutex_);
    hasPending_ = false;
    pendingSnapshot_.reset();
    if (devicePresent_ && sourceVoice_)
    {
        sourceVoice_->Stop(0);
        sourceVoice_->FlushSourceBuffers();
    }
}
