#include "PlaybackClock.h"

#include <cmath>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace
{
    int64_t QpcNow()
    {
        LARGE_INTEGER v;
        QueryPerformanceCounter(&v);
        return v.QuadPart;
    }

    int64_t QpcFrequency()
    {
        LARGE_INTEGER v;
        QueryPerformanceFrequency(&v);
        return v.QuadPart != 0 ? v.QuadPart : 1;
    }
}

PlaybackClock::PlaybackClock()
{
    qpcFrequency_ = QpcFrequency();
    qpc_ = [] { return QpcNow(); };
    samples_ = [] { return uint64_t{0}; };
}

void PlaybackClock::Configure(double fps, uint32_t sampleRate, SamplesReader samples, QpcReader qpc, int64_t qpcFrequency)
{
    SetFps(fps);
    sampleRate_ = sampleRate != 0 ? sampleRate : 48000;
    samples_ = samples ? std::move(samples) : SamplesReader([] { return uint64_t{0}; });
    qpc_ = qpc ? std::move(qpc) : QpcReader([] { return int64_t{0}; });
    qpcFrequency_ = qpcFrequency != 0 ? qpcFrequency : 1;
}

void PlaybackClock::Rebase(int64_t frame, bool usingAudioClock)
{
    rebaseFrame_ = frame;
    rebaseQpc_ = qpc_ ? qpc_() : 0;
    rebaseSamples_ = samples_ ? samples_() : 0;
    usingAudioClock_ = usingAudioClock;
}

int64_t PlaybackClock::CurrentFrame() const
{
    if (rate_ == 0.0)
    {
        return rebaseFrame_; // frozen (doc §3.2 paused branch) — no reader touched
    }

    double elapsedSeconds;
    if (usingAudioClock_)
    {
        const uint64_t played = samples_ ? samples_() : 0;
        // SamplesPlayed is monotonic within one audio-clock interval (a rebase re-anchors it on
        // any voice restart), so the clamp only guards a transient read straddling a rebase.
        const uint64_t delta = played >= rebaseSamples_ ? played - rebaseSamples_ : 0;
        elapsedSeconds = static_cast<double>(delta) / static_cast<double>(sampleRate_);
    }
    else
    {
        const int64_t now = qpc_ ? qpc_() : 0;
        int64_t ticks = now - rebaseQpc_;
        if (ticks < 0)
        {
            ticks = 0;
        }
        elapsedSeconds = static_cast<double>(ticks) / static_cast<double>(qpcFrequency_);
    }
    return rebaseFrame_ + static_cast<int64_t>(std::floor(elapsedSeconds * fps_ * rate_));
}

int32_t PE_PlaybackClockSelfTest(int64_t* outFrames, int32_t cap, int32_t* outCount)
{
    if (!outFrames || cap <= 0)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }

    // Fake readers, no audio device: a QPC tick source at 10 MHz (100 ns ticks, Windows-like) and
    // a SamplesPlayed counter at 48 kHz, both advanced by hand between steps so the audio, QPC,
    // freeze, rebase, and seamless-handover branches are all asserted deterministically.
    constexpr int64_t kQpcFreq = 10'000'000;
    constexpr uint32_t kRate = 48'000;
    int64_t qpcTicks = 0;
    uint64_t samples = 0;

    PlaybackClock clock;
    clock.Configure(30.0, kRate, [&] { return samples; }, [&] { return qpcTicks; }, kQpcFreq);

    int32_t n = 0;
    auto record = [&](int64_t f) { if (n < cap) { outFrames[n++] = f; } };

    // 0: paused at 0 -> frozen 0.
    clock.SetRate(0.0);
    clock.Rebase(0, false);
    record(clock.CurrentFrame());

    // 1: play on the QPC clock from 0; +0.5 s -> 15.
    clock.SetRate(1.0);
    clock.Rebase(0, false);
    qpcTicks += kQpcFreq / 2;
    record(clock.CurrentFrame());

    // 2: +0.5 s more (1.0 s total) -> 30.
    qpcTicks += kQpcFreq / 2;
    record(clock.CurrentFrame());

    // 3: seamless handover to the audio clock at the current frame -> still 30 (no jump).
    const int64_t handoff = clock.CurrentFrame();
    samples = 123'456; // arbitrary live SamplesPlayed value at the moment of handover
    clock.Rebase(handoff, true);
    record(clock.CurrentFrame());

    // 4: audio advances 0.5 s (24000 sample-frames) -> 45.
    samples += kRate / 2;
    record(clock.CurrentFrame());

    // 5: pause freezes at 45 even as both readers keep running.
    const int64_t frozen = clock.CurrentFrame();
    clock.SetRate(0.0);
    clock.Rebase(frozen, false);
    qpcTicks += kQpcFreq;
    samples += kRate;
    record(clock.CurrentFrame());

    // 6: seek-rebase to 100 while paused -> 100.
    clock.Rebase(100, false);
    record(clock.CurrentFrame());

    // 7: resume on the QPC clock from 100; +0.25 s -> 107 (100 + floor(7.5)).
    clock.SetRate(1.0);
    clock.Rebase(100, false);
    qpcTicks += kQpcFreq / 4;
    record(clock.CurrentFrame());

    if (outCount)
    {
        *outCount = n;
    }
    return PE_OK;
}
