#pragma once

#include "include/palmier_engine.h"
#include "Compositor.h"
#include "D3D11Presenter.h"
#include "GpuCompositor.h"
#include "MediaCache.h"
#include "PlaybackClock.h"
#include "TimelineSnapshot.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

class EngineSession;
class AudioMixer;
class AudioEngine;
class ScrubAudio;

// Owns one open timeline: its current snapshot (atomically swappable via shared_ptr —
// PE_UpdateTimeline never blocks or interrupts an in-flight render; the render in flight
// keeps the OLD snapshot alive through its own shared_ptr copy and finishes against it),
// a per-timeline decoder cache, a dedicated render worker thread implementing the scrub
// machinery (latest-wins mailbox coalesced to ~30Hz for interactive scrub, cancellable
// in-flight decode, immediate dispatch for exact/settle seeks), and its own D3D11
// swap-chain presenter sharing the owning session's single D3D11 device/context (see
// EngineSession::EnsureGraphicsDeviceShared / GraphicsMutex).
//
// Registers/unregisters itself in TimelineRegistry (constructor/destructor) so the
// handle-only ABI entry points (no session parameter) can validate a PE_TimelineHandle
// without a lookup through EngineSession's own per-session map.
class TimelineSession
{
public:
    explicit TimelineSession(EngineSession* owner);
    ~TimelineSession();

    TimelineSession(const TimelineSession&) = delete;
    TimelineSession& operator=(const TimelineSession&) = delete;

    bool Open(const std::string& utf8SnapshotJson, std::string& outError);
    bool Update(const std::string& utf8SnapshotJson, std::string& outError);

    // Rebuild vs RefreshParams split (plan's "Render graph" / ABI section). Reuses the SAME
    // decoder/media sessions as Update() (mediaCache_ is untouched by either — see Update()'s
    // comment) but additionally ASSERTS the new snapshot's media set (the set of distinct
    // mediaPath values across every clip) is identical to the current one, refusing the swap
    // (returns false, outError set) if it isn't — a structural media-set change must go through
    // Update()/PE_UpdateTimeline instead. This is what makes RefreshParams a genuine "params
    // only, no rebuild" contract rather than just an alias for Update().
    bool RefreshParams(const std::string& utf8SnapshotJson, std::string& outError);

    // Enqueues (InteractiveScrub) or dispatches (Exact/other) a seek; never blocks on the
    // render thread.
    int32_t Seek(int64_t frame, int32_t mode);

    int32_t AttachSwapChain(void* swapChainPanelUnknown, int32_t width, int32_t height, std::string& outError);
    int32_t ResizeSwapChain(int32_t width, int32_t height, std::string& outError);
    int32_t DetachSwapChain(std::string& outError);

    // Synchronous, headless — bypasses the render thread/mailbox entirely (the golden
    // hook: deterministic, immune to scrub throttling/coalescing/cancellation).
    bool RenderFrameToFile(int64_t frame, const std::string& utf8PngPath, std::string& outError);

    // E6 color scopes (docs/color-scopes-v1.md) — synchronous GPU compute of `frame`'s live
    // Y/R/G/B + hue histograms, same threading contract as RenderFrameToFile (bypasses the
    // render thread/mailbox, unaffected by a concurrent Seek). Always uses the GPU compositor
    // path (never the PALMIERENGINE_FORCE_CPU_COMPOSITOR fallback — scopes have no CPU
    // equivalent); fails if no D3D11 device (hardware or WARP) is available at all.
    // outResult.frame is stamped with `frame` on success.
    bool ComputeColorScopes(int64_t frame, PE_ColorScopesResult& outResult, std::string& outError);

    // Offline audio mix (docs/audio-playback-v1.md §6) — fills outInterleavedStereo (sampleCount × 2
    // floats) with the current snapshot's mix for the 48 kHz range starting at timeline `startFrame`.
    // No XAudio2 device involved: deterministic, the CI-facing hook for the mix loop. The same
    // AudioMixer instance is reused so a per-clip decode cursor persists across successive ranges.
    bool RenderAudioRange(int64_t startFrame, int32_t sampleCount, float* outInterleavedStereo, std::string& outError);

    // Latest-wins windowed audio grab at `frame` (docs/audio-playback-v1.md §5) — plays once
    // through a lightweight voice separate from the persistent playback voice. A no-op (not an
    // error) if this timeline has no open snapshot yet.
    void ScrubAudioAt(int64_t frame, int32_t direction);

    // Cuts off any still-playing scrub grain and drops any pending one (docs/audio-playback-v1.md
    // §5). The Exact-settle counterpart to ScrubAudioAt — mirrors the Mac's
    // ScrubAudioEngine.stopScrubbing() on a .exact seek (VideoEngine.swift). A no-op if no scrub
    // grain has ever played on this timeline (the lightweight voice is created lazily).
    void StopScrubAudio();

    // Offline golden hook behind PE_TimelineRenderScrubGrain (docs/audio-playback-v1.md §5) —
    // synchronously computes the same grain ScrubAudioAt would play, without touching any
    // XAudio2 device. Same lazily-created ScrubAudio instance as ScrubAudioAt.
    bool RenderScrubGrain(int64_t frame, int32_t direction, float* outInterleavedStereo, std::string& outError);

    void SetPlayheadCallback(PE_PlayheadCallback callback, void* userCtx);

    // Master meter tap (Stage E, AudioMeterView) — raw linear-amplitude peak + RMS per channel
    // from the most recently mixed audio block, written by UpdateAudioLevels (below) from BOTH
    // RenderAudioRange (offline; what the deterministic Category=Media test and
    // PE_TimelineRenderAudioRange drive, no XAudio2 device) and FillAudio (live; what actual
    // Play() drives). Reads all zero (silence) before either producer has ever run. Values are
    // NOT dB and NOT clamped — the C# AudioMeterHub port (PalmierPro.Core.Audio) owns the dB
    // mapping/decay/peak-hold/clip-latch ballistics, mirroring the Mac's AudioMeterChannelState
    // (Audio/AudioMeter.swift) exactly.
    void GetAudioLevels(float& outLeftPeak, float& outLeftRms, float& outRightPeak, float& outRightRms) const;

    // E4.5 playback / A/V clock (docs/audio-playback-v1.md §3, §4). Play/Pause/SetRate rebase the
    // master clock and drive the render thread's present loop (§3.5); GetClockFrame reads the
    // current clock position synchronously (never blocks). Idempotent Play/Pause mirror AVPlayer.
    int32_t Play();
    int32_t Pause();
    int32_t SetRate(double rate);
    int32_t GetClockFrame(int64_t* outFrame);
    void SetIsPlayingCallback(PE_IsPlayingCallback callback, void* userCtx);

    // Test/debug-only: is the master clock currently on the sample-locked audio path (true) or the
    // QPC software fallback (false)? Reads clock_ under clockMutex_. Backs
    // PE_DebugTimelineUsingAudioClock — the QPC→audio handover is otherwise unobservable through
    // the ABI, so the device-gated handover test can't assert re-engagement without it.
    bool DebugUsingAudioClock();

    // JSON array of media paths the engine itself failed to decode while composing — see
    // docs/timeline-snapshot-v1.md §8 for the distinction from the builder-side
    // OfflineMediaRefs. Owned by this timeline; valid until the next call that could
    // invalidate it.
    const char* UnprocessableMediaRefsJson();

private:
    EngineSession* owner_;

    std::mutex snapshotMutex_;
    std::shared_ptr<const TimelineSnapshot> snapshot_;

    MediaCache mediaCache_;

    // Decode-once-cache-as-static-texture for "image" clips — separate from MediaCache's
    // video LRU since a still image never expires under frame pressure.
    struct CachedImage { std::vector<uint8_t> bgra; int32_t width = 0; int32_t height = 0; };
    std::mutex imageCacheMutex_;
    std::unordered_map<std::string, CachedImage> imageCache_;

    std::mutex unprocessableMutex_;
    std::set<std::string> unprocessableMediaRefs_;
    std::string unprocessableJsonScratch_;

    // Render thread / mailbox.
    std::thread renderThread_;
    std::mutex mailboxMutex_;
    std::condition_variable mailboxCv_;
    bool stopRequested_ = false;
    bool hasPending_ = false;
    int64_t pendingFrame_ = 0;
    int32_t pendingMode_ = PE_SEEK_EXACT;
    std::atomic<int32_t> cancelDecode_{0};
    std::chrono::steady_clock::time_point lastInteractiveDispatch_{};

    std::mutex presenterMutex_;
    std::unique_ptr<D3D11Presenter> presenter_;

    // Default render path (see ComposeFrame) — lazily created against the owning session's
    // shared D3D11 device/context (owner_->GraphicsMutex() serializes every use, same as
    // presenter_). Compositor::Compose (CPU) is only reached when
    // PALMIERENGINE_FORCE_CPU_COMPOSITOR is set — see ComposeFrame's comment.
    std::unique_ptr<GpuCompositor> gpuCompositor_;

    std::mutex playheadMutex_;
    PE_PlayheadCallback playheadCallback_ = nullptr;
    void* playheadUserCtx_ = nullptr;

    // E4.5 audio mix (docs/audio-playback-v1.md §9 "mix"). Lazily created; owns its own per-clip
    // audio decoders, entirely independent of mediaCache_'s video decode path.
    std::mutex audioMixerMutex_;
    std::unique_ptr<AudioMixer> audioMixer_;

    // E4.5 scrub (docs/audio-playback-v1.md §9 "scrub"). Lazily created; owns its own per-clip
    // audio decoders and lightweight one-shot voice, entirely independent of audioMixer_'s.
    std::mutex audioScrubMutex_;
    std::unique_ptr<ScrubAudio> audioScrub_;

    // --- E4.5 playback / A/V clock (docs/audio-playback-v1.md §3) ---------------------------
    //
    // The persistent per-timeline source voice + master clock. clockMutex_ guards clock_ and the
    // isPlaying flag and is only ever held for O(1) work (never across a blocking voice op), so
    // GetClockFrame never blocks. The voice's Start/Stop/Flush and voiceStarted_/audio-mode flips
    // are done ONLY on the render thread (RenderThreadLoop / PlaybackPresentTick) — Play/Pause/Seek
    // just set clock state + intent and wake it, so no cross-thread voice contention exists.
    std::unique_ptr<AudioEngine> audioEngine_;   // lazily created on first Play (device or null-device)
    std::unique_ptr<AudioMixer> playbackMixer_;  // live-fill mixer, separate from audioMixer_ (offline)
    PlaybackClock clock_;
    std::mutex clockMutex_;
    std::atomic<bool> isPlaying_{false};

    // Render-thread-only playback state (no lock: written/read solely on renderThread_).
    bool voiceStarted_ = false;          // is the persistent voice currently Started?
    uint64_t voiceStartBaseline_ = 0;    // SamplesPlayed observed at the last fresh Start (reset detect)
    int64_t lastPresentedFrame_ = -1;    // present-loop + seek de-dupe

    // Live audio fill (submit-thread) cursor + whole-frame staging. fillMutex_ guards all three.
    std::mutex fillMutex_;
    int64_t fillCursorSample_ = 0;       // next timeline 48 kHz sample-frame the fill will emit
    int64_t stagingBaseSample_ = 0;      // timeline sample-frame of stagingInterleaved_[0]
    int64_t nextRenderFrame_ = 0;        // next timeline frame to render into staging
    std::vector<float> stagingInterleaved_;

    std::mutex isPlayingCbMutex_;
    PE_IsPlayingCallback isPlayingCallback_ = nullptr;
    void* isPlayingUserCtx_ = nullptr;

    // Master meter tap storage (see GetAudioLevels above). Plain atomics, no mutex: the two
    // writers (RenderAudioRange on whatever thread calls PE_TimelineRenderAudioRange; FillAudio
    // on the audio submission thread) and the one reader (GetAudioLevels, polled from the UI
    // thread) never need to observe all four values as a single atomic unit — a UI meter
    // momentarily seeing peak/RMS from two adjacent blocks is harmless, and this is what keeps
    // the tap genuinely lock-free (never blocks behind FillAudio's decode work).
    std::atomic<float> levelLeftPeak_{0.0f};
    std::atomic<float> levelLeftRms_{0.0f};
    std::atomic<float> levelRightPeak_{0.0f};
    std::atomic<float> levelRightRms_{0.0f};
    void UpdateAudioLevels(const float* interleavedStereo, int32_t sampleCount);

    void RenderThreadLoop();
    void PlaybackPresentTick();
    void PresentComposed(const ComposeResult& result);
    void FirePlayhead(int64_t frame);
    void FireIsPlaying(bool isPlaying);
    void NudgePresentIfPaused();
    void EnsureAudioEngine();
    void FillAudio(float* dstInterleavedStereo, uint32_t frameCount);
    void SetFillCursorToFrameLocked(int64_t frame); // fillMutex_ held by caller
    bool AnyAudibleAt(const TimelineSnapshot& snapshot, int64_t frame) const;
    static int64_t TimelineDurationFrames(const TimelineSnapshot& snapshot);

    bool ComposeFrame(int64_t frame, bool interactive, const std::atomic<int32_t>* cancelFlag,
        ComposeResult& outResult, std::string& outError);
    bool ProvideClipFrame(const SnapshotClip& clip, double sourceSeconds, bool interactive,
        const std::atomic<int32_t>* cancelFlag, double timelineFps, DecodedSourceFrame& outFrame,
        std::vector<uint8_t>& scratch);
    void MarkUnprocessable(const std::string& mediaPath);
};

// Test/debug-only probe for the E4.5 clock slice (docs/audio-playback-v1.md §3.4) — writes 1 to
// *outUsingAudioClock if `timeline`'s master clock is on the sample-locked audio path, 0 if on the
// QPC software fallback. Deliberately NOT part of the normative ABI in include/palmier_engine.h
// (same one-slice-test-seam convention as PE_PlaybackClockSelfTest / PE_AudioEngineSmokeTest): the
// QPC→audio handover is otherwise unobservable through the ABI, so the device-gated
// play→pause→play handover test can't assert the clock re-engages the audio path without it.
// PE_ERROR_INVALID_ARGUMENT for a null out; PE_ERROR_INVALID_HANDLE for an unknown/closed timeline.
PALMIER_API int32_t PE_DebugTimelineUsingAudioClock(PE_TimelineHandle timeline, int32_t* outUsingAudioClock);
