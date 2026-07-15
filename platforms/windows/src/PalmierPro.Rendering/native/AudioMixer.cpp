#include "AudioMixer.h"

#include "MediaSource.h"
#include "RetimeStretcher.h"

#include <algorithm>
#include <cmath>

namespace
{
    // PalmierPro.Core.Models.VolumeScale (Timeline.cs:33) clamp bounds.
    constexpr double kVolumeScaleFloorDb = -60.0;
    constexpr double kVolumeScaleCeilingDb = 15.0;

    // Port of VolumeScale.LinearFromDb (Timeline.cs:46) — clamp to [-60, +15] dB, floor == hard mute.
    double LinearFromDb(double db)
    {
        if (db <= kVolumeScaleFloorDb)
        {
            return 0.0;
        }
        return std::pow(10.0, std::min(db, kVolumeScaleCeilingDb) / 20.0);
    }

    // Port of Clip.FadeMultiplier (Timeline.cs:342): min of the head/tail ramps, 0 outside
    // [startFrame, startFrame + durationFrames]. Interpolation smooth == t*t*(3-2t), else linear.
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

    // dB keyframe track sampled at the (clip-relative) frame; empty == unity, 0 dB fallback == unity.
    // Mirrors Clip.VolumeAt's kfGain term (Timeline.cs:322).
    double DbKeyframeGain(const SnapshotClip& c, int64_t timelineFrame)
    {
        if (c.volumeKeyframes.empty())
        {
            return 1.0;
        }
        double db = SampleKeyframeTrack(c.volumeKeyframes, timelineFrame - c.startFrame, 0.0, InterpolateDouble);
        return LinearFromDb(db);
    }
}

AudioMixer::AudioMixer() = default;
AudioMixer::~AudioMixer() = default;

MediaSource* AudioMixer::AcquireDecoder(const std::string& clipId, const std::string& mediaPath)
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

// Lazily constructs (once) and configures the clip's stretcher. Configure() is idempotent to
// call again but pointless — the mix format never changes — so this only runs on first use.
RetimeStretcher* AudioMixer::AcquireRetimeStretcher(ClipDecoder& entry)
{
    if (!entry.retime)
    {
        entry.retime = std::make_unique<RetimeStretcher>();
        entry.retime->Configure(static_cast<int32_t>(kChannels), static_cast<double>(kMixSampleRate));
    }
    return entry.retime.get();
}

bool AudioMixer::RenderRange(const TimelineSnapshot& snapshot, int64_t startFrame, int32_t sampleCount,
    float* outInterleavedStereo, std::string& outError)
{
    if (sampleCount <= 0 || !outInterleavedStereo)
    {
        outError = "invalid audio render range";
        return false;
    }

    const double fps = snapshot.Fps();
    const double samplesPerFrame = static_cast<double>(kMixSampleRate) / fps;
    const double baseTimelineSample = static_cast<double>(startFrame) * samplesPerFrame;

    accumL_.assign(static_cast<size_t>(kBlockFrames), 0.0f);
    accumR_.assign(static_cast<size_t>(kBlockFrames), 0.0f);

    for (int32_t blockStart = 0; blockStart < sampleCount; blockStart += kBlockFrames)
    {
        const int32_t blockLen = std::min(kBlockFrames, sampleCount - blockStart);
        std::fill_n(accumL_.begin(), blockLen, 0.0f);
        std::fill_n(accumR_.begin(), blockLen, 0.0f);

        // Block-cadence timeline frame (doc §2): gain + clip activation are sampled once per block.
        const int64_t blockTimelineFrame = startFrame +
            static_cast<int64_t>(std::floor(static_cast<double>(blockStart) * fps / kMixSampleRate));

        for (const SnapshotTrack& track : snapshot.tracks)
        {
            if (track.type != SnapshotTrackType::Audio || track.muted)
            {
                continue; // video contributes nothing; a muted track is skipped whole (doc §6.1)
            }

            const SnapshotClip* clip = nullptr;
            for (const SnapshotClip& c : track.clips)
            {
                if (c.ContainsFrame(blockTimelineFrame))
                {
                    clip = &c;
                    break; // clips are ordered and non-overlapping within a track
                }
            }
            if (!clip)
            {
                continue;
            }

            // audio.denoise (Clip.denoiseEffectType) travels in clip.effects but is a Phase-3
            // wet/dry render — decoded into the snapshot, bypassed here (doc §1).

            MediaSource* decoder = AcquireDecoder(clip->id, clip->mediaPath);
            if (!decoder)
            {
                continue;
            }

            const double gain = clip->volumeGain * DbKeyframeGain(*clip, blockTimelineFrame) *
                FadeMultiplier(*clip, blockTimelineFrame);

            const double trimStartSample = static_cast<double>(clip->trimStartFrame) * samplesPerFrame;
            const double clipStartSample = static_cast<double>(clip->startFrame) * samplesPerFrame;
            auto srcPosExact = [&](int32_t g) {
                return trimStartSample + ((baseTimelineSample + g) - clipStartSample) * clip->speed;
            };

            if (clip->speed != 1.0)
            {
                // §6 step 2: retimed sample stream through the pitch-preserving stretcher.
                // Duration mapping is the same trimStart + (frame-startFrame)*speed source↔timeline
                // math as srcPosExact/the compositor (Compositor.cpp:112-114) — but unlike the
                // speed==1 path below, the stretcher (not linear interpolation) is what turns a
                // `blockLen * speed`-sample source run into exactly `blockLen` output samples, so
                // pitch stays put while duration follows speed.
                ClipDecoder& entry = decoders_.at(clip->id);
                RetimeStretcher* retime = AcquireRetimeStretcher(entry);

                // srcPosExact(blockStart) is only consulted here, to detect a discontinuity (clip
                // just became active this block, or a seek/gap moved the cursor) — once primed, the
                // stretcher's own continuity is carried by entry.retimeSourceCursor, not
                // recomputed from this every block, so per-block rounding can't fight the ideal.
                const double idealCursor = srcPosExact(blockStart);
                if (!entry.retimePrimed || std::abs(entry.retimeSourceCursor - idealCursor) > kBlockFrames * 2)
                {
                    retime->Reset();
                    entry.retimeSourceCursor = idealCursor;
                    entry.retimePrimed = true;

                    // Prime the STFT history with real pre-roll so the first block after this Reset is
                    // at full amplitude instead of fading in over ~60 ms (signalsmith outputLatency) —
                    // audible at every retimed-clip activation and every post-seek re-activation. Feed
                    // the block+hop of source ending exactly at the cursor; the next Process() below
                    // continues contiguously from the same cursor. When fewer samples exist before the
                    // cursor (clip head / timeline start) a partial pre-roll still primes better than
                    // none; at cursor 0 there is nothing to feed and the ramp-up is unavoidable.
                    const int64_t cursorInt = static_cast<int64_t>(std::floor(idealCursor));
                    const int32_t preRoll = static_cast<int32_t>(
                        std::min<int64_t>(retime->PrerollSampleFrames(), cursorInt));
                    if (preRoll > 0)
                    {
                        const int64_t preStart = cursorInt - preRoll;
                        clipL_.resize(static_cast<size_t>(preRoll));
                        clipR_.resize(static_cast<size_t>(preRoll));
                        std::string primeError;
                        if (decoder->ReadAudioStereo48k(preStart, preRoll, clipL_.data(), clipR_.data(), primeError))
                        {
                            retime->Seek(clipL_.data(), clipR_.data(), preRoll, clip->speed);
                        }
                    }
                }

                // Floor-difference ("Bresenham") cursor advance: decodeCount for this block is
                // derived from the running double cursor, not re-rounded from scratch each time, so
                // per-block fractional error never accumulates drift over a long clip.
                const double nextCursor = entry.retimeSourceCursor + static_cast<double>(blockLen) * clip->speed;
                const int64_t srcStartInt = static_cast<int64_t>(std::floor(entry.retimeSourceCursor));
                const int64_t srcEndInt = static_cast<int64_t>(std::floor(nextCursor));
                const int32_t decodeCount = static_cast<int32_t>(std::max<int64_t>(1, srcEndInt - srcStartInt));
                entry.retimeSourceCursor = nextCursor;

                clipL_.resize(static_cast<size_t>(decodeCount));
                clipR_.resize(static_cast<size_t>(decodeCount));
                std::string decodeError;
                if (!decoder->ReadAudioStereo48k(srcStartInt, decodeCount, clipL_.data(), clipR_.data(), decodeError))
                {
                    continue; // decode setup miss for this clip -> its silence, not a whole-render failure
                }

                retimedL_.resize(static_cast<size_t>(blockLen));
                retimedR_.resize(static_cast<size_t>(blockLen));
                retime->Process(clipL_.data(), clipR_.data(), decodeCount, retimedL_.data(), retimedR_.data(), blockLen);

                for (int32_t j = 0; j < blockLen; ++j)
                {
                    accumL_[static_cast<size_t>(j)] += static_cast<float>(gain * retimedL_[static_cast<size_t>(j)]);
                    accumR_[static_cast<size_t>(j)] += static_cast<float>(gain * retimedR_[static_cast<size_t>(j)]);
                }
                continue;
            }

            const double srcMin = srcPosExact(blockStart);
            const double srcMax = srcPosExact(blockStart + blockLen - 1);
            const int64_t srcStartInt = static_cast<int64_t>(std::floor(std::min(srcMin, srcMax)));
            const int64_t srcEndInt = static_cast<int64_t>(std::floor(std::max(srcMin, srcMax))) + 2;
            const int32_t decodeCount = static_cast<int32_t>(std::max<int64_t>(1, srcEndInt - srcStartInt));

            clipL_.resize(static_cast<size_t>(decodeCount));
            clipR_.resize(static_cast<size_t>(decodeCount));
            std::string decodeError;
            if (!decoder->ReadAudioStereo48k(srcStartInt, decodeCount, clipL_.data(), clipR_.data(), decodeError))
            {
                continue; // decode setup miss for this clip -> its silence, not a whole-render failure
            }

            for (int32_t j = 0; j < blockLen; ++j)
            {
                const double pos = srcPosExact(blockStart + j) - static_cast<double>(srcStartInt);
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
                accumL_[static_cast<size_t>(j)] += static_cast<float>(gain * l);
                accumR_[static_cast<size_t>(j)] += static_cast<float>(gain * r);
            }
        }

        // Interleave once (doc §2). No limiter/clamp: a multi-clip sum past ±1.0 passes straight
        // through and clips at the device, matching the Mac's unlimited AVAudioMix — a deliberate
        // parity decision (doc §2), so the intermediate float buffer a retimed/multi-clip golden
        // compares against is bit-for-bit the same unbounded sum the Mac produces.
        for (int32_t j = 0; j < blockLen; ++j)
        {
            float* dst = outInterleavedStereo + static_cast<size_t>(blockStart + j) * kChannels;
            dst[0] = accumL_[static_cast<size_t>(j)];
            dst[1] = accumR_[static_cast<size_t>(j)];
        }
    }

    (void)outError;
    return true;
}
