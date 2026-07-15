#pragma once

#include <cstdint>
#include <memory>

// Pitch-preserving time stretch for one audio clip's decode path
// (docs/audio-playback-v1.md §6 step 2: "running the retimed sample stream through
// the WSOLA-style pitch-preserving stretcher when speed != 1.0"). Wraps the vendored
// signalsmith-stretch (native/third_party/signalsmith-stretch/, MIT, v1.1.0) — an
// STFT-based stretcher, not literally WSOLA, but fills the same contract the doc
// describes: consume `inputCount` source-rate samples, produce `outputCount` samples
// spanning a different duration, pitch unchanged.
//
// One instance belongs to exactly one clip (AudioMixer keys it alongside that clip's
// MediaSource) and carries STFT phase/history state across consecutive Process()
// calls — callers must feed it the *contiguous* next chunk of that clip's source
// audio every call, in block order, and Reset() before feeding anything else
// (clip (re)activation, a timeline seek, or any other source-cursor discontinuity).
//
// Seam for a future "clock"/rate-play feature: v1's PE_TimelineSetRate only accepts
// {0.0, 1.0} (docs/audio-playback-v1.md §4) — there is no continuously-variable
// playback-rate ("shuttle") case yet, so nothing here is wired to it. A future
// variable-rate preview would need this same pitch-preserving path applied to the
// whole mix bus rather than per-clip; this class doesn't attempt that, only clip.speed
// retiming.
class RetimeStretcher
{
public:
    RetimeStretcher();
    ~RetimeStretcher();

    RetimeStretcher(const RetimeStretcher&) = delete;
    RetimeStretcher& operator=(const RetimeStretcher&) = delete;

    void Configure(int32_t channels, double sampleRate);

    // Drops all internal STFT/history state. Call before the next Process() call's
    // input is anything other than the direct continuation of the previous call's —
    // i.e. whenever the mixer's source cursor for this clip jumps.
    void Reset();

    // Source-rate samples of pre-roll to feed Seek() for a full-amplitude first block: one
    // STFT block + one hop (signalsmith blockSamples + intervalSamples). Seek() clamps to whatever
    // fewer samples the caller can actually supply, so this is the ideal, not a hard minimum.
    int32_t PrerollSampleFrames() const;

    // Prime the STFT history after Reset() with `inputCount` source samples that immediately
    // PRECEDE the next Process() input (the clip's current source cursor), so the first Process()
    // block emerges at full amplitude instead of ramping up over ~outputLatency (windowSize/2 ≈
    // 60 ms). `playbackRate` is the same input/output sample ratio Process() runs at (clip.speed).
    // Feeds signalsmith's own seek() pre-roll path — it consumes only the trailing
    // PrerollSampleFrames() of `inL`/`inR` and advances no output. Planar, matches Process().
    void Seek(const float* inL, const float* inR, int32_t inputCount, double playbackRate);

    // Reads exactly inputCount source-rate samples per channel from inL/inR and
    // writes exactly outputCount retimed samples per channel to outL/outR — pitch
    // unchanged regardless of inputCount != outputCount. Planar, not interleaved
    // (matches AudioMixer's own accumulator convention).
    void Process(const float* inL, const float* inR, int32_t inputCount,
        float* outL, float* outR, int32_t outputCount);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
