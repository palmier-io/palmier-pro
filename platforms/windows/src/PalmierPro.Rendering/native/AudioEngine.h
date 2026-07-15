#pragma once

#include "include/palmier_engine.h"

#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <semaphore>
#include <thread>
#include <vector>

struct IXAudio2;
struct IXAudio2MasteringVoice;
struct IXAudio2SourceVoice;

// E4.5 infra slice (docs/audio-playback-v1.md §9 "infra"). Owns the XAudio2 device,
// mastering voice, and ONE persistent float32/stereo/48 kHz source voice per open
// timeline — the single long-lived voice whose SamplesPlayed counter the A/V clock reads
// (doc §3). Deliberately knows nothing about timeline mixing: a dedicated submission
// thread pulls each block from a FillCallback the mixer (docs §6, separate slice) fills,
// so this file can be exercised end-to-end (see PE_AudioEngineSmokeTest) before the mixer
// exists.
//
// No-device fallback (doc §3.4 trigger 2): if XAudio2/mastering-voice/source-voice
// creation fails — expected on a CI runner with no audio endpoint, mirroring
// EngineSession's HARDWARE→WARP D3D11 fallback — Initialize still succeeds and enters
// null-device mode. Every primitive below becomes a successful no-op and IsDevicePresent()
// returns false, so the caller drives the QPC software clock instead. This never surfaces
// as a failure.
class AudioEngine
{
public:
    using FillCallback = std::function<void(float* dstInterleavedStereo, uint32_t frameCount)>;

    static constexpr uint32_t kSampleRate = 48000;
    static constexpr uint32_t kChannels = 2;
    static constexpr uint32_t kDefaultBlockFrames = 960;   // 20 ms @ 48 kHz (doc §2)
    static constexpr uint32_t kDefaultQueuedBlocks = 4;     // ~80 ms buffered lead time (doc §2)
    static constexpr std::ptrdiff_t kMaxQueuedBlocks = 16;

    // Both declared here but defined (= default) in the .cpp, not inline: callback_ is a
    // unique_ptr<VoiceCallback>, and VoiceCallback is only forward-declared in this header — an
    // inline-defaulted ctor/dtor would get instantiated at whatever call site first constructs/
    // destroys an AudioEngine (e.g. TimelineSession.cpp), which never sees VoiceCallback's
    // complete type. Deferring to the .cpp (which defines VoiceCallback) is the standard
    // pimpl-adjacent fix — same reason AudioMixer's own ctor/dtor are out-of-line for
    // RetimeStretcher (AudioMixer.h).
    AudioEngine();
    ~AudioEngine();
    AudioEngine(const AudioEngine&) = delete;
    AudioEngine& operator=(const AudioEngine&) = delete;

    // Heap-allocate one from another translation unit (TimelineSession) without needing the
    // private VoiceCallback definition: the constructor instantiates HERE, where VoiceCallback is
    // complete, instead of forcing every make_unique<AudioEngine> caller to see it. The returned
    // unique_ptr still destroys through the out-of-line ~AudioEngine, so no caller needs it either.
    static std::unique_ptr<AudioEngine> Create();

    // Creates the device + mastering voice + persistent source voice. Falls back to
    // null-device mode (returns true, IsDevicePresent() == false) on any device failure;
    // returns false only for an unexpected internal error (bad geometry args).
    bool Initialize(uint32_t blockFrames = kDefaultBlockFrames, uint32_t queuedBlocks = kDefaultQueuedBlocks);

    bool IsDevicePresent() const { return devicePresent_; }

    // The mixer fills `dstInterleavedStereo` with exactly `frameCount` interleaved L/R
    // float samples each time the pipeline needs another block. Invoked on this engine's
    // submission thread — never on the XAudio2 callback thread, so it may block on decode.
    // Set before Start; if unset, blocks are submitted as silence.
    void SetFillCallback(FillCallback fill) { fill_ = std::move(fill); }

    // Flush the voice, prime the queue from the fill callback, and Start (doc §3.3). Idempotent.
    void Start();
    // Stop the voice, discard queued audio, and halt the pull loop (doc §3.3 Pause path).
    // Idempotent.
    void Stop();
    // Discard queued-but-unplayed audio without tearing down the pull loop — the raw
    // FlushSourceBuffers primitive the infra rebase logic composes with Stop/Start.
    void Flush();

    // Voice SamplesPlayed since the last Start following Flush/creation. XAudio2 defines this
    // as samples already PLAYED — it excludes samples still sitting in the submitted-but-
    // unplayed queue, so it is already the "total submitted minus still-queued" playback
    // position with no manual subtraction (doc §3). 0 in null-device mode (caller uses QPC).
    uint64_t PlayedSampleFrames() const;

    // Buffers still queued in the voice (including the one currently playing). 0 in null mode.
    uint32_t QueuedBlocks() const;

    uint32_t BlockFrames() const { return blockFrames_; }
    static constexpr uint32_t SampleRate() { return kSampleRate; }
    static constexpr uint32_t Channels() { return kChannels; }

private:
    class VoiceCallback;
    friend class VoiceCallback;

    void SubmitLoop();
    void SubmitBlock(uint32_t slot);
    void OnBufferComplete() { freeSem_.release(); }

    Microsoft::WRL::ComPtr<IXAudio2> xaudio2_;
    IXAudio2MasteringVoice* masteringVoice_ = nullptr;   // owned via DestroyVoice, not IUnknown
    IXAudio2SourceVoice* sourceVoice_ = nullptr;         // owned via DestroyVoice, not IUnknown
    std::unique_ptr<VoiceCallback> callback_;

    bool devicePresent_ = false;
    uint32_t blockFrames_ = kDefaultBlockFrames;
    uint32_t queuedBlocks_ = kDefaultQueuedBlocks;
    uint32_t blockBytes_ = 0;
    std::vector<std::vector<float>> ringBuffers_;

    FillCallback fill_;
    std::thread submitThread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stopping_{false};
    uint32_t nextSlot_ = 0;
    std::counting_semaphore<kMaxQueuedBlocks> freeSem_{0};
};

// Self-test hook for the E4.5 infra slice — deliberately NOT part of the normative ABI in
// include/palmier_engine.h (that header is the cross-agent contract; this is a one-slice
// smoke seam). Generates `ms` (defaults to 200 if <= 0) of a stereo sine through the
// persistent source voice when an audio device exists, or exercises the null-device
// fallback path otherwise — never crashes on a device-less CI runner. On return:
// *outDevicePresent is 1 if a real device drove playback, 0 if the null-device fallback ran;
// *outPlayedFrames is the voice SamplesPlayed after playback (0 in null mode). Either
// pointer may be null. Returns PE_OK on both paths.
PALMIER_API int32_t PE_AudioEngineSmokeTest(int32_t ms, int32_t* outDevicePresent, uint64_t* outPlayedFrames);
