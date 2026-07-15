#pragma once

#include "include/palmier_engine.h"

#include <cstdint>
#include <functional>

// E4.5 clock slice (docs/audio-playback-v1.md §3). The A/V master clock as pure math over a small
// rebase-state struct plus two injected readers — the persistent voice's SamplesPlayed counter and
// a QueryPerformanceCounter tick source. No XAudio2/D3D11 dependency, so it unit-tests with fake
// readers on a device-less runner (PE_PlaybackClockSelfTest below), mirroring SeekCoordinator's
// injected-scheduler testability. TimelineSession owns one per open timeline and serializes every
// call through its own clockMutex_ — this type does no locking of its own.
class PlaybackClock
{
public:
    using SamplesReader = std::function<uint64_t()>; // voice SamplesPlayed, 48 kHz sample-frames
    using QpcReader = std::function<int64_t()>;      // QueryPerformanceCounter ticks

    // Default: real QueryPerformanceCounter, its frequency, and a zero SamplesPlayed reader (until
    // an audible timeline voice supplies one via SetSamplesReader).
    PlaybackClock();

    // Full injection for the self-test — replaces both readers, the fps, sample rate, and the QPC
    // frequency so a scenario can drive deterministic tick/sample math with no audio device.
    void Configure(double fps, uint32_t sampleRate, SamplesReader samples, QpcReader qpc, int64_t qpcFrequency);

    void SetFps(double fps) { fps_ = fps > 0.0 ? fps : 30.0; }
    void SetSamplesReader(SamplesReader samples) { samples_ = std::move(samples); }

    // Re-anchor all three reference points to `frame` NOW (doc §3.1/§3.3): rebaseFrame = frame,
    // rebaseQpc = QPC now, rebaseSamples = SamplesPlayed now. `usingAudioClock` selects the
    // SamplesPlayed vs QPC branch for subsequent reads — the caller only passes true once the
    // voice is actually counting (TimelineSession's flow-confirmation), so rebaseSamples anchors
    // to a live post-reset value rather than a stale pre-Start one.
    void Rebase(int64_t frame, bool usingAudioClock);

    // doc §3.2: paused (rate 0) -> frozen rebaseFrame (O(1), touches no reader); playing + audio ->
    // rebaseFrame + floor(elapsedSamples / sampleRate * fps); playing + QPC -> the QPC analogue.
    int64_t CurrentFrame() const;

    void SetRate(double rate) { rate_ = rate; }
    double Rate() const { return rate_; }
    bool UsingAudioClock() const { return usingAudioClock_; }
    int64_t RebaseFrame() const { return rebaseFrame_; }

private:
    double fps_ = 30.0;
    uint32_t sampleRate_ = 48000;
    int64_t qpcFrequency_ = 1;
    SamplesReader samples_;
    QpcReader qpc_;

    int64_t rebaseFrame_ = 0;
    int64_t rebaseQpc_ = 0;
    uint64_t rebaseSamples_ = 0;
    double rate_ = 0.0;
    bool usingAudioClock_ = false;
};

// Self-test hook for the E4.5 clock slice — deliberately NOT part of the normative ABI in
// include/palmier_engine.h (that header is the cross-agent contract; this is a one-slice test
// seam, mirroring AudioEngine.h's PE_AudioEngineSmokeTest). Drives a real PlaybackClock through a
// fixed scenario with hand-driven fake QPC + SamplesPlayed readers, writing the clock frame
// observed at each step into outFrames (up to `cap` entries; *outCount receives the step count).
// Lets the audio, QPC, freeze, rebase, and seamless-handover branches be asserted from a
// device-less test. PE_ERROR_INVALID_ARGUMENT for a null buffer or cap <= 0.
PALMIER_API int32_t PE_PlaybackClockSelfTest(int64_t* outFrames, int32_t cap, int32_t* outCount);
