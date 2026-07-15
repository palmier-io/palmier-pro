#include "AudioEngine.h"

#include <windows.h>
#include <xaudio2.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace
{
    // Forces null-device mode without a real endpoint failure — mirrors EngineSession's
    // PALMIERENGINE_FORCE_WARP, so CI can exercise the doc §3.4 fallback deterministically
    // even on a machine that has audio. GetEnvironmentVariableA, not _dupenv_s: the latter
    // reads this DLL's CRT-cached environ snapshot, whose init timing vs. a managed
    // caller's SetEnvironmentVariable call differs by config — GetEnvironmentVariableA
    // always queries the live OS environment block instead.
    bool ForceNullAudioRequested()
    {
        char value[8]{};
        DWORD len = GetEnvironmentVariableA("PALMIERENGINE_FORCE_NULL_AUDIO", value, sizeof(value));
        return len > 0 && len < sizeof(value) && value[0] != '0';
    }
}

// XAudio2 posts OnBufferEnd on its own audio thread; we only bump the free-block
// semaphore there and do the (potentially slow) refill/decode on submitThread_.
class AudioEngine::VoiceCallback : public IXAudio2VoiceCallback
{
public:
    explicit VoiceCallback(AudioEngine* owner) : owner_(owner) {}

    void STDMETHODCALLTYPE OnBufferEnd(void*) noexcept override { owner_->OnBufferComplete(); }

    void STDMETHODCALLTYPE OnVoiceProcessingPassStart(UINT32) noexcept override {}
    void STDMETHODCALLTYPE OnVoiceProcessingPassEnd() noexcept override {}
    void STDMETHODCALLTYPE OnStreamEnd() noexcept override {}
    void STDMETHODCALLTYPE OnBufferStart(void*) noexcept override {}
    void STDMETHODCALLTYPE OnLoopEnd(void*) noexcept override {}
    void STDMETHODCALLTYPE OnVoiceError(void*, HRESULT) noexcept override {}

private:
    AudioEngine* owner_;
};

std::unique_ptr<AudioEngine> AudioEngine::Create()
{
    return std::unique_ptr<AudioEngine>(new AudioEngine());
}

AudioEngine::AudioEngine() = default;

AudioEngine::~AudioEngine()
{
    Stop();
    // DestroyVoice flushes and guarantees no further callbacks before it returns, so it must
    // precede releasing xaudio2_ and destroying callback_.
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

bool AudioEngine::Initialize(uint32_t blockFrames, uint32_t queuedBlocks)
{
    if (blockFrames == 0 || queuedBlocks == 0)
    {
        return false;
    }
    blockFrames_ = blockFrames;
    queuedBlocks_ = std::min<uint32_t>(queuedBlocks, static_cast<uint32_t>(kMaxQueuedBlocks));
    blockBytes_ = blockFrames_ * kChannels * static_cast<uint32_t>(sizeof(float));
    ringBuffers_.assign(queuedBlocks_, std::vector<float>(static_cast<size_t>(blockFrames_) * kChannels, 0.0f));

    // Any failure below is the doc §3.4 no-device path, not an error: leave devicePresent_
    // false and return true so the caller runs on the QPC software clock.
    if (ForceNullAudioRequested())
    {
        return true;
    }
    if (FAILED(XAudio2Create(xaudio2_.ReleaseAndGetAddressOf(), 0, XAUDIO2_DEFAULT_PROCESSOR)))
    {
        return true;
    }
    // Mastering voice at device defaults (0, 0) — XAudio2's sample-rate converter maps our
    // fixed 48 kHz source to whatever the endpoint runs, keeping SamplesPlayed in 48 kHz units.
    if (FAILED(xaudio2_->CreateMasteringVoice(&masteringVoice_, 0, 0)))
    {
        xaudio2_.Reset();
        return true;
    }

    WAVEFORMATEX wfx{};
    wfx.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    wfx.nChannels = static_cast<WORD>(kChannels);
    wfx.nSamplesPerSec = kSampleRate;
    wfx.wBitsPerSample = 32;
    wfx.nBlockAlign = static_cast<WORD>(kChannels * sizeof(float));
    wfx.nAvgBytesPerSec = kSampleRate * wfx.nBlockAlign;
    wfx.cbSize = 0;

    callback_ = std::make_unique<VoiceCallback>(this);
    if (FAILED(xaudio2_->CreateSourceVoice(&sourceVoice_, &wfx, 0, XAUDIO2_DEFAULT_FREQ_RATIO, callback_.get(), nullptr, nullptr)))
    {
        if (masteringVoice_)
        {
            masteringVoice_->DestroyVoice();
            masteringVoice_ = nullptr;
        }
        xaudio2_.Reset();
        callback_.reset();
        return true;
    }

    devicePresent_ = true;
    return true;
}

void AudioEngine::Start()
{
    if (running_.exchange(true))
    {
        return;
    }
    if (!devicePresent_)
    {
        return;
    }

    sourceVoice_->Stop(0);
    sourceVoice_->FlushSourceBuffers();
    while (freeSem_.try_acquire())
    {
    }
    nextSlot_ = 0;
    stopping_.store(false, std::memory_order_release);
    for (uint32_t i = 0; i < queuedBlocks_; ++i)
    {
        freeSem_.release();
    }
    submitThread_ = std::thread(&AudioEngine::SubmitLoop, this);
}

void AudioEngine::Stop()
{
    if (!running_.exchange(false))
    {
        return;
    }
    if (!devicePresent_)
    {
        return;
    }

    stopping_.store(true, std::memory_order_release);
    sourceVoice_->Stop(0);
    sourceVoice_->FlushSourceBuffers();
    freeSem_.release();   // unblock the submit thread if it's parked on acquire()
    if (submitThread_.joinable())
    {
        submitThread_.join();
    }
}

void AudioEngine::Flush()
{
    if (devicePresent_ && sourceVoice_)
    {
        sourceVoice_->FlushSourceBuffers();
    }
}

void AudioEngine::SubmitLoop()
{
    bool started = false;
    uint32_t submittedSinceStart = 0;
    while (true)
    {
        freeSem_.acquire();
        if (stopping_.load(std::memory_order_acquire))
        {
            break;
        }
        SubmitBlock(nextSlot_);
        nextSlot_ = (nextSlot_ + 1) % queuedBlocks_;
        if (!started && ++submittedSinceStart >= queuedBlocks_)
        {
            // Start only once the queue is primed, so the voice never underruns on the
            // very first block.
            sourceVoice_->Start(0);
            started = true;
        }
    }
}

void AudioEngine::SubmitBlock(uint32_t slot)
{
    float* buffer = ringBuffers_[slot].data();
    if (fill_)
    {
        fill_(buffer, blockFrames_);
    }
    else
    {
        std::memset(buffer, 0, blockBytes_);
    }

    XAUDIO2_BUFFER xb{};
    xb.AudioBytes = blockBytes_;
    xb.pAudioData = reinterpret_cast<const BYTE*>(buffer);
    sourceVoice_->SubmitSourceBuffer(&xb);
}

uint64_t AudioEngine::PlayedSampleFrames() const
{
    if (!devicePresent_ || !sourceVoice_)
    {
        return 0;
    }
    XAUDIO2_VOICE_STATE state{};
    sourceVoice_->GetState(&state, 0);
    return state.SamplesPlayed;
}

uint32_t AudioEngine::QueuedBlocks() const
{
    if (!devicePresent_ || !sourceVoice_)
    {
        return 0;
    }
    XAUDIO2_VOICE_STATE state{};
    sourceVoice_->GetState(&state, 0);
    return state.BuffersQueued;
}

int32_t PE_AudioEngineSmokeTest(int32_t ms, int32_t* outDevicePresent, uint64_t* outPlayedFrames)
{
    const int32_t durationMs = ms > 0 ? ms : 200;

    AudioEngine engine;
    if (!engine.Initialize())
    {
        return PE_ERROR_UNKNOWN;
    }

    constexpr double kTwoPi = 6.283185307179586;
    const double step = kTwoPi * 440.0 / AudioEngine::SampleRate();
    double phase = 0.0;
    engine.SetFillCallback([step, phase](float* dst, uint32_t frames) mutable
    {
        for (uint32_t i = 0; i < frames; ++i)
        {
            const float sample = static_cast<float>(std::sin(phase) * 0.2);
            dst[i * 2] = sample;
            dst[i * 2 + 1] = sample;
            phase += step;
            if (phase >= kTwoPi)
            {
                phase -= kTwoPi;
            }
        }
    });

    engine.Start();
    std::this_thread::sleep_for(std::chrono::milliseconds(durationMs));
    const uint64_t played = engine.PlayedSampleFrames();
    engine.Stop();

    if (outDevicePresent)
    {
        *outDevicePresent = engine.IsDevicePresent() ? 1 : 0;
    }
    if (outPlayedFrames)
    {
        *outPlayedFrames = played;
    }
    return PE_OK;
}
