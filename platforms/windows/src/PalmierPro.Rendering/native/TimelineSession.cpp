#include "TimelineSession.h"
#include "AudioEngine.h"
#include "AudioMixer.h"
#include "EngineSession.h"
#include "ScrubAudio.h"
#include "TimelineRegistry.h"
#include "TimelineSnapshotParser.h"
#include "WicImageReader.h"
#include "WicPngWriter.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace
{
    constexpr auto kInteractiveThrottleInterval = std::chrono::milliseconds(33); // ~30 Hz

    // Playback present-loop poll cadence (doc §3.5): ~120 Hz, decoupled from the timeline fps so a
    // 60 fps timeline on a high-refresh display never visibly misses a frame boundary, and Windows
    // sleep imprecision at exactly 1/fps is a non-issue. Each tick presents the LATEST clock frame
    // and drops any it skipped past — never a queued backlog.
    constexpr auto kPresentPollInterval = std::chrono::milliseconds(8);

    // GPU compositing (GpuCompositor) is the DEFAULT render path (plan: "MOVE COMPOSITING TO
    // D3D11"). Compositor::Compose (CPU) stays compiled and reachable ONLY behind this explicit
    // flag — mirrors EngineSession.cpp's PALMIERENGINE_FORCE_WARP pattern exactly, so CI can
    // still exercise the CPU fallback deliberately (see GPU-vs-CPU-fallback-consistency tests)
    // without it silently running as a second live path day-to-day. The CPU path does NOT
    // support effects/keyframes (v1 geometry-only compositor, unchanged) — see Compositor.h.
    bool CpuCompositorForced()
    {
        char* value = nullptr;
        size_t len = 0;
        if (_dupenv_s(&value, &len, "PALMIERENGINE_FORCE_CPU_COMPOSITOR") != 0 || !value)
        {
            return false;
        }
        bool forced = len > 0 && value[0] != '0';
        free(value);
        return forced;
    }

    // Distinct mediaPath values across every clip of every track — the "media set" RefreshParams
    // asserts is unchanged (docs/timeline-snapshot-v1.md's Rebuild-vs-RefreshParams split).
    std::set<std::string> MediaPathSet(const TimelineSnapshot& snapshot)
    {
        std::set<std::string> paths;
        for (const SnapshotTrack& track : snapshot.tracks)
        {
            for (const SnapshotClip& clip : track.clips)
            {
                paths.insert(clip.mediaPath);
            }
        }
        return paths;
    }

    void AppendJsonEscaped(std::string& out, const std::string& s)
    {
        out += '"';
        for (unsigned char c : s)
        {
            switch (c)
            {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (c < 0x20)
                    {
                        char buf[8];
                        std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                        out += buf;
                    }
                    else
                    {
                        out += static_cast<char>(c);
                    }
            }
        }
        out += '"';
    }
}

TimelineSession::TimelineSession(EngineSession* owner) : owner_(owner)
{
    TimelineRegistry::Register(this);
}

TimelineSession::~TimelineSession()
{
    {
        std::lock_guard<std::mutex> lock(mailboxMutex_);
        stopRequested_ = true;
    }
    mailboxCv_.notify_all();
    if (renderThread_.joinable())
    {
        renderThread_.join();
    }
    // Tear the persistent voice down HERE, before member destruction: AudioEngine's own destructor
    // joins its submit thread, whose FillAudio touches playbackMixer_/staging — both of which
    // (declared after audioEngine_) would already be gone by the time audioEngine_ destructed on
    // its own. The render thread is already joined, so nothing else touches the voice now.
    audioEngine_.reset();
    std::string ignored;
    DetachSwapChain(ignored);
    TimelineRegistry::Unregister(this);
}

bool TimelineSession::Open(const std::string& utf8SnapshotJson, std::string& outError)
{
    TimelineSnapshot parsed;
    if (!TimelineSnapshotParser::Parse(utf8SnapshotJson, parsed, outError))
    {
        return false;
    }
    double fps = parsed.Fps();
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot_ = std::make_shared<const TimelineSnapshot>(std::move(parsed));
    }
    {
        std::lock_guard<std::mutex> clockLock(clockMutex_);
        clock_.SetFps(fps);
    }
    if (!renderThread_.joinable())
    {
        renderThread_ = std::thread(&TimelineSession::RenderThreadLoop, this);
    }
    return true;
}

bool TimelineSession::Update(const std::string& utf8SnapshotJson, std::string& outError)
{
    TimelineSnapshot parsed;
    if (!TimelineSnapshotParser::Parse(utf8SnapshotJson, parsed, outError))
    {
        owner_->SetLastError(outError);
        return false;
    }
    double fps = parsed.Fps();
    auto next = std::make_shared<const TimelineSnapshot>(std::move(parsed));
    // Atomic pointer swap: ComposeFrame() takes its own shared_ptr copy of snapshot_
    // under this same mutex before rendering, so a render already past that point keeps
    // the OLD TimelineSnapshot alive via refcount and finishes against it — "in-flight
    // renders finish on the old snapshot," per the plan.
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot_ = next;
    }
    std::lock_guard<std::mutex> clockLock(clockMutex_);
    clock_.SetFps(fps);
    return true;
}

bool TimelineSession::RefreshParams(const std::string& utf8SnapshotJson, std::string& outError)
{
    TimelineSnapshot parsed;
    if (!TimelineSnapshotParser::Parse(utf8SnapshotJson, parsed, outError))
    {
        owner_->SetLastError(outError);
        return false;
    }

    std::shared_ptr<const TimelineSnapshot> currentSnapshot;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        currentSnapshot = snapshot_;
    }
    if (!currentSnapshot)
    {
        outError = "RefreshParams called before any snapshot was opened";
        owner_->SetLastError(outError);
        return false;
    }
    if (MediaPathSet(*currentSnapshot) != MediaPathSet(parsed))
    {
        outError = "RefreshParams: media set changed — this is a structural rebuild "
            "(use PE_UpdateTimeline/Update instead of PE_TimelineRefreshParams)";
        owner_->SetLastError(outError);
        return false;
    }

    // Same atomic-swap contract as Update() — mediaCache_ is untouched either way, so this
    // call was already implicitly "no decoder rebuild"; the media-set assertion above is what
    // makes that guarantee explicit/checked rather than incidental.
    double fps = parsed.Fps();
    auto next = std::make_shared<const TimelineSnapshot>(std::move(parsed));
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot_ = next;
    }
    std::lock_guard<std::mutex> clockLock(clockMutex_);
    clock_.SetFps(fps);
    return true;
}

int32_t TimelineSession::Seek(int64_t frame, int32_t mode)
{
    // Clock rebase (doc §3.3): a seek while playing re-anchors the master clock to `frame` and
    // playback CONTINUES from there (it does not implicitly pause — that is caller policy). While
    // paused, rate is 0 so the rebase simply moves the frozen frame. The persistent voice's own
    // FlushSourceBuffers (below) is thread-safe to call here; its Start/Stop and any audio-vs-QPC
    // mode flip stay on the render thread, which re-evaluates audibility for `frame` next tick.
    if (isPlaying_.load(std::memory_order_relaxed))
    {
        {
            std::lock_guard<std::mutex> fillLock(fillMutex_);
            SetFillCursorToFrameLocked(frame);
        }
        if (audioEngine_ && audioEngine_->IsDevicePresent())
        {
            audioEngine_->Flush(); // discard queued old-position audio; refill resumes from `frame`
        }
        std::lock_guard<std::mutex> clockLock(clockMutex_);
        clock_.Rebase(frame, clock_.UsingAudioClock());
    }
    else
    {
        std::lock_guard<std::mutex> clockLock(clockMutex_);
        clock_.Rebase(frame, false); // paused: frozen at `frame` (rate 0, branch irrelevant)
    }

    {
        std::lock_guard<std::mutex> lock(mailboxMutex_);
        pendingFrame_ = frame;
        pendingMode_ = mode;
        hasPending_ = true;
        if (mode != PE_SEEK_INTERACTIVE_SCRUB)
        {
            // Exact/settle seeks are high priority: cancel whatever stale interactive
            // compose might be in flight so the worker picks this up promptly instead of
            // finishing a now-superseded scrub frame first.
            cancelDecode_.store(1, std::memory_order_relaxed);
        }
    }
    mailboxCv_.notify_one();
    return PE_OK;
}

void TimelineSession::RenderThreadLoop()
{
    // Two modes on one thread (doc §3.5): a seek-reactive mailbox (block on the CV until a seek
    // arrives — the E2 behavior) AND, once PE_TimelinePlay is active, a present loop that wakes on
    // a short timeout to schedule frames against the master clock. Serialized on one thread so the
    // GPU compositor + presenter are never used concurrently. All persistent-voice Start/Stop and
    // audio-vs-QPC mode flips live here too, so no other thread touches the voice lifecycle.
    for (;;)
    {
        int64_t frame = 0;
        int32_t mode = PE_SEEK_EXACT;
        bool hadSeek = false;
        bool playing = false;
        {
            std::unique_lock<std::mutex> lock(mailboxMutex_);
            if (isPlaying_.load(std::memory_order_relaxed))
            {
                mailboxCv_.wait_for(lock, kPresentPollInterval, [&] { return stopRequested_ || hasPending_; });
            }
            else
            {
                // isPlaying_ is in the predicate too: PE_TimelinePlay flips it and notifies without
                // setting hasPending_, so without this the wake would fail the predicate and the
                // thread would sleep on through the whole playback (present loop never entered).
                mailboxCv_.wait(lock, [&] {
                    return stopRequested_ || hasPending_ || isPlaying_.load(std::memory_order_relaxed);
                });
            }
            if (stopRequested_)
            {
                return;
            }
            playing = isPlaying_.load(std::memory_order_relaxed);
            if (hasPending_)
            {
                frame = pendingFrame_;
                mode = pendingMode_;
                hasPending_ = false;
                hadSeek = true;
            }
        }

        // Stop the persistent voice once playback has ended (PE_TimelinePause froze the clock and
        // cleared isPlaying_, or the present loop hit end-of-timeline) — done here so voice Stop
        // (which joins the submit thread) never runs under clockMutex_.
        if (voiceStarted_ && !isPlaying_.load(std::memory_order_relaxed))
        {
            audioEngine_->Stop();
            voiceStarted_ = false;
        }

        if (hadSeek)
        {
            bool interactive = (mode == PE_SEEK_INTERACTIVE_SCRUB);
            if (interactive)
            {
                auto elapsed = std::chrono::steady_clock::now() - lastInteractiveDispatch_;
                if (elapsed < kInteractiveThrottleInterval)
                {
                    std::this_thread::sleep_for(kInteractiveThrottleInterval - elapsed);
                    // Latest-wins: a newer request may have arrived while we slept.
                    std::lock_guard<std::mutex> lock(mailboxMutex_);
                    if (hasPending_)
                    {
                        frame = pendingFrame_;
                        mode = pendingMode_;
                        interactive = (mode == PE_SEEK_INTERACTIVE_SCRUB);
                        hasPending_ = false;
                    }
                }
            }

            cancelDecode_.store(0, std::memory_order_relaxed);
            ComposeResult result;
            std::string error;
            bool ok = ComposeFrame(frame, interactive, &cancelDecode_, result, error);
            if (interactive)
            {
                // Mirrors VideoEngine.swift: lastInteractiveDispatchTime is only ever touched inside
                // flushPendingInteractiveSeek (the interactive path). An exact/settle dispatch must
                // not push the throttle clock forward, or it can needlessly delay the first frame of
                // the next scrub by up to a full throttle interval.
                lastInteractiveDispatch_ = std::chrono::steady_clock::now();
            }
            if (ok)
            {
                PresentComposed(result);
                FirePlayhead(frame);
                lastPresentedFrame_ = frame;
            }
        }

        if (playing)
        {
            PlaybackPresentTick();
        }
    }
}

void TimelineSession::PresentComposed(const ComposeResult& result)
{
    std::lock_guard<std::mutex> presenterLock(presenterMutex_);
    if (presenter_ && presenter_->IsAttached())
    {
        std::string presentError;
        std::lock_guard<std::recursive_mutex> gfxLock(owner_->GraphicsMutex());
        presenter_->PresentBgra(result.bgra.data(), result.width, result.height, result.strideBytes, presentError);
    }
}

void TimelineSession::FirePlayhead(int64_t frame)
{
    std::lock_guard<std::mutex> phLock(playheadMutex_);
    if (playheadCallback_)
    {
        playheadCallback_(playheadUserCtx_, frame);
    }
}

// One present-loop iteration (doc §3.5). Reads the LATEST clock frame, resolves the audio-vs-QPC
// mode (implicit rebases on an audibility flip), auto-stops at end-of-timeline, and composes +
// presents only when the frame actually changed — skipped frames are dropped, never queued.
void TimelineSession::PlaybackPresentTick()
{
    std::shared_ptr<const TimelineSnapshot> snapshot;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot = snapshot_;
    }
    if (!snapshot)
    {
        return;
    }
    const int64_t duration = TimelineDurationFrames(*snapshot);

    int64_t frame = 0;
    bool ended = false;
    enum { VoiceNone, VoiceStart, VoiceStop } voiceAction = VoiceNone;
    {
        std::lock_guard<std::mutex> clockLock(clockMutex_);
        if (!isPlaying_.load(std::memory_order_relaxed))
        {
            return; // paused between the wake and here
        }
        frame = clock_.CurrentFrame();

        if (duration > 0 && frame >= duration)
        {
            // Auto-stop at end (doc §3.5): the same freeze PE_TimelinePause does, at the duration
            // boundary, then PE_IsPlayingCallback(false) below — mirrors the Mac's periodic-observer
            // auto-pause, which is engine-internal there too.
            frame = duration;
            clock_.SetRate(0.0);
            clock_.Rebase(frame, false);
            isPlaying_.store(false, std::memory_order_relaxed);
            ended = true;
        }
        else
        {
            const bool devicePresent = audioEngine_ && audioEngine_->IsDevicePresent();
            const bool audible = devicePresent && AnyAudibleAt(*snapshot, frame);
            if (audible)
            {
                if (!voiceStarted_)
                {
                    voiceAction = VoiceStart; // start fresh; stay on QPC until flow is confirmed
                }
                else if (!clock_.UsingAudioClock())
                {
                    // Confirm the voice is actually counting before flipping to the audio clock, so
                    // rebaseSamples anchors to a live playing value. XAudio2's SamplesPlayed on this
                    // persistent voice is cumulative and monotonic — Stop/FlushSourceBuffers/Start do
                    // NOT reset it (empirically verified) — so any advance past the pre-Start baseline
                    // proves the voice has begun playing this run. The subsequent Rebase re-anchors
                    // rebaseSamples to the current cumulative value, so PlaybackClock's played -
                    // rebaseSamples delta stays continuous regardless (also subsumes baseline == 0).
                    const uint64_t played = audioEngine_->PlayedSampleFrames();
                    const bool confirmed = played > voiceStartBaseline_;
                    if (confirmed)
                    {
                        clock_.Rebase(frame, true); // seamless QPC -> audio handoff AT `frame`
                    }
                }
            }
            else
            {
                if (voiceStarted_)
                {
                    voiceAction = VoiceStop;
                }
                if (clock_.UsingAudioClock())
                {
                    clock_.Rebase(frame, false); // seamless audio -> QPC handoff AT `frame`
                }
            }
        }
    }

    // Blocking voice ops OUTSIDE clockMutex_ (VoiceStart spawns, VoiceStop joins the submit thread).
    if (voiceAction == VoiceStart)
    {
        {
            std::lock_guard<std::mutex> fillLock(fillMutex_);
            SetFillCursorToFrameLocked(frame);
        }
        voiceStartBaseline_ = audioEngine_->PlayedSampleFrames();
        audioEngine_->Start();
        voiceStarted_ = true;
    }
    else if (voiceAction == VoiceStop)
    {
        audioEngine_->Stop();
        voiceStarted_ = false;
    }

    if (frame != lastPresentedFrame_)
    {
        cancelDecode_.store(0, std::memory_order_relaxed);
        ComposeResult result;
        std::string error;
        if (ComposeFrame(frame, /*interactive*/ false, &cancelDecode_, result, error))
        {
            PresentComposed(result);
            FirePlayhead(frame);
            lastPresentedFrame_ = frame;
        }
    }

    if (ended)
    {
        if (voiceStarted_)
        {
            audioEngine_->Stop();
            voiceStarted_ = false;
        }
        FireIsPlaying(false);
    }
}

bool TimelineSession::ComposeFrame(int64_t frame, bool interactive, const std::atomic<int32_t>* cancelFlag,
    ComposeResult& outResult, std::string& outError)
{
    std::shared_ptr<const TimelineSnapshot> snapshot;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot = snapshot_;
    }
    if (!snapshot)
    {
        outError = "timeline has no open snapshot";
        return false;
    }

    double fps = snapshot->Fps();
    std::vector<uint8_t> scratch; // reused clip-to-clip within this single compose pass only
    ClipFrameProvider provider = [&](const SnapshotClip& clip, double sourceSeconds, DecodedSourceFrame& outFrame) -> bool {
        return ProvideClipFrame(clip, sourceSeconds, interactive, cancelFlag, fps, outFrame, scratch);
    };

    if (CpuCompositorForced())
    {
        return Compositor::Compose(*snapshot, frame, provider, cancelFlag, outResult, outError);
    }

    // GPU is the default path — see the CpuCompositorForced() comment. The immediate D3D11
    // context is shared session-wide (MediaSource's opportunistic D3D11VA readback, the
    // presenter's Present/Resize) — GraphicsMutex() serializes every submission exactly like
    // presenter_->PresentBgra already does in RenderThreadLoop.
    std::string deviceError;
    ID3D11Device* device = owner_->EnsureGraphicsDeviceShared(deviceError);
    if (!device)
    {
        // No D3D11 device at all (hardware AND WARP both failed to create) — fall back to the
        // CPU compositor rather than fail the whole render; this is the one path where running
        // the CPU compositor isn't behind the explicit env flag, since there is no GPU path to
        // prefer.
        return Compositor::Compose(*snapshot, frame, provider, cancelFlag, outResult, outError);
    }

    std::lock_guard<std::recursive_mutex> gfxLock(owner_->GraphicsMutex());
    if (!gpuCompositor_)
    {
        gpuCompositor_ = std::make_unique<GpuCompositor>(device, owner_->GraphicsContext());
    }
    return gpuCompositor_->Compose(*snapshot, frame, provider, cancelFlag, outResult, outError);
}

bool TimelineSession::ProvideClipFrame(const SnapshotClip& clip, double sourceSeconds, bool interactive,
    const std::atomic<int32_t>* cancelFlag, double timelineFps, DecodedSourceFrame& outFrame, std::vector<uint8_t>& scratch)
{
    if (clip.type == SnapshotClipType::Image)
    {
        int32_t width = 0, height = 0;
        {
            std::lock_guard<std::mutex> lock(imageCacheMutex_);
            auto found = imageCache_.find(clip.mediaPath);
            if (found != imageCache_.end())
            {
                scratch = found->second.bgra; // copy out under lock — see header comment
                width = found->second.width;
                height = found->second.height;
            }
        }
        if (width == 0)
        {
            std::vector<uint8_t> decoded;
            int32_t w = 0, h = 0;
            std::string error;
            if (!WicImageReader::ReadToBgra(clip.mediaPath, decoded, w, h, error))
            {
                MarkUnprocessable(clip.mediaPath);
                return false;
            }
            {
                std::lock_guard<std::mutex> lock(imageCacheMutex_);
                imageCache_[clip.mediaPath] = CachedImage{decoded, w, h};
            }
            scratch = std::move(decoded);
            width = w;
            height = h;
        }
        outFrame.bgra = scratch.data();
        outFrame.width = width;
        outFrame.height = height;
        outFrame.strideBytes = width * 4;
        return true;
    }

    std::string deviceError;
    ID3D11Device* device = owner_->EnsureGraphicsDeviceShared(deviceError); // best-effort; nullptr -> software decode
    bool deviceIsHardware = device != nullptr && owner_->IsGraphicsDeviceHardware();

    std::string openError;
    MediaSource* media = mediaCache_.Acquire(clip.mediaPath, device, deviceIsHardware, openError);
    if (!media)
    {
        MarkUnprocessable(clip.mediaPath);
        return false;
    }

    // Quantized at timelineFps, not the source's own frame rate — for an fps-mismatched or
    // retimed clip, distinct source frames can round to the same frameKey (and vice versa). Known
    // v1 limitation; not addressed here.
    int64_t frameKey = static_cast<int64_t>(std::llround(sourceSeconds * timelineFps));

    int32_t cw = 0, ch = 0, cstride = 0;
    if (mediaCache_.TryGetFrame(media, frameKey, interactive, scratch, cw, ch, cstride))
    {
        outFrame.bgra = scratch.data();
        outFrame.width = cw;
        outFrame.height = ch;
        outFrame.strideBytes = cstride;
        return true;
    }

    PE_FrameBuffer frame{};
    std::string decodeError;
    if (!media->DecodeFrameAtEx(sourceSeconds, interactive, cancelFlag, frame, decodeError))
    {
        if (decodeError != "cancelled")
        {
            MarkUnprocessable(clip.mediaPath);
        }
        return false;
    }

    scratch.assign(frame.data, frame.data + static_cast<size_t>(frame.strideBytes) * frame.height);
    outFrame.bgra = scratch.data();
    outFrame.width = frame.width;
    outFrame.height = frame.height;
    outFrame.strideBytes = frame.strideBytes;
    // `interactive` is exactly the "was this decode approximate" flag DecodeFrameAtEx used —
    // never let an approximate decode masquerade as an exact one in the cache (see MediaCache.h).
    mediaCache_.PutFrame(media, frameKey, /*approximate*/ interactive, scratch.data(), frame.width, frame.height, frame.strideBytes);
    return true;
}

void TimelineSession::MarkUnprocessable(const std::string& mediaPath)
{
    std::lock_guard<std::mutex> lock(unprocessableMutex_);
    unprocessableMediaRefs_.insert(mediaPath);
}

const char* TimelineSession::UnprocessableMediaRefsJson()
{
    std::lock_guard<std::mutex> lock(unprocessableMutex_);
    unprocessableJsonScratch_ = "[";
    bool first = true;
    for (const std::string& path : unprocessableMediaRefs_)
    {
        if (!first)
        {
            unprocessableJsonScratch_ += ",";
        }
        first = false;
        AppendJsonEscaped(unprocessableJsonScratch_, path);
    }
    unprocessableJsonScratch_ += "]";
    return unprocessableJsonScratch_.c_str();
}

int32_t TimelineSession::AttachSwapChain(void* swapChainPanelUnknown, int32_t width, int32_t height, std::string& outError)
{
    ID3D11Device* device = owner_->EnsureGraphicsDeviceShared(outError);
    if (!device)
    {
        return PE_ERROR_UNKNOWN;
    }
    std::lock_guard<std::mutex> presenterLock(presenterMutex_);
    if (!presenter_)
    {
        presenter_ = std::make_unique<D3D11Presenter>();
    }
    std::lock_guard<std::recursive_mutex> gfxLock(owner_->GraphicsMutex());
    if (!presenter_->Attach(device, owner_->GraphicsContext(), swapChainPanelUnknown, width, height, outError))
    {
        return PE_ERROR_UNKNOWN;
    }
    return PE_OK;
}

int32_t TimelineSession::ResizeSwapChain(int32_t width, int32_t height, std::string& outError)
{
    std::lock_guard<std::mutex> presenterLock(presenterMutex_);
    if (!presenter_ || !presenter_->IsAttached())
    {
        outError = "no swap chain attached";
        return PE_ERROR_INVALID_HANDLE;
    }
    std::lock_guard<std::recursive_mutex> gfxLock(owner_->GraphicsMutex());
    if (!presenter_->Resize(width, height, outError))
    {
        return PE_ERROR_UNKNOWN;
    }
    return PE_OK;
}

int32_t TimelineSession::DetachSwapChain(std::string& outError)
{
    std::lock_guard<std::mutex> presenterLock(presenterMutex_);
    if (presenter_)
    {
        std::lock_guard<std::recursive_mutex> gfxLock(owner_->GraphicsMutex());
        presenter_->Detach();
    }
    outError.clear();
    return PE_OK;
}

bool TimelineSession::RenderFrameToFile(int64_t frame, const std::string& utf8PngPath, std::string& outError)
{
    // Dedicated per-call-thread cancel flag (always 0): this synchronous golden hook must
    // never be aborted by a concurrent PE_TimelineSeek on another thread setting the
    // render thread's own cancelDecode_ flag.
    static thread_local std::atomic<int32_t> noCancel{0};
    ComposeResult result;
    try
    {
        if (!ComposeFrame(frame, /*interactive*/ false, &noCancel, result, outError))
        {
            owner_->SetLastError(outError);
            return false;
        }
    }
    catch (const std::exception& ex)
    {
        outError = std::string("ComposeFrame threw: ") + ex.what();
        owner_->SetLastError(outError);
        return false;
    }
    if (!WicPngWriter::WriteBgraToPng(result.bgra.data(), result.width, result.height, result.strideBytes, utf8PngPath, outError))
    {
        owner_->SetLastError(outError);
        return false;
    }
    return true;
}

bool TimelineSession::RenderAudioRange(int64_t startFrame, int32_t sampleCount, float* outInterleavedStereo, std::string& outError)
{
    std::shared_ptr<const TimelineSnapshot> snapshot;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot = snapshot_;
    }
    if (!snapshot)
    {
        outError = "timeline has no open snapshot";
        owner_->SetLastError(outError);
        return false;
    }

    std::lock_guard<std::mutex> mixerLock(audioMixerMutex_);
    if (!audioMixer_)
    {
        audioMixer_ = std::make_unique<AudioMixer>();
    }
    if (!audioMixer_->RenderRange(*snapshot, startFrame, sampleCount, outInterleavedStereo, outError))
    {
        owner_->SetLastError(outError);
        return false;
    }
    return true;
}

void TimelineSession::ScrubAudioAt(int64_t frame, int32_t direction)
{
    std::shared_ptr<const TimelineSnapshot> snapshot;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot = snapshot_;
    }
    if (!snapshot)
    {
        return; // nothing open yet — never fails on content grounds (doc §5)
    }

    std::lock_guard<std::mutex> scrubLock(audioScrubMutex_);
    if (!audioScrub_)
    {
        audioScrub_ = std::make_unique<ScrubAudio>();
    }
    audioScrub_->Play(std::move(snapshot), frame, direction);
}

void TimelineSession::StopScrubAudio()
{
    std::lock_guard<std::mutex> scrubLock(audioScrubMutex_);
    if (audioScrub_)
    {
        audioScrub_->Stop(); // no-op if the lightweight voice never got a device (doc §5)
    }
}

bool TimelineSession::RenderScrubGrain(int64_t frame, int32_t direction, float* outInterleavedStereo, std::string& outError)
{
    std::shared_ptr<const TimelineSnapshot> snapshot;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot = snapshot_;
    }
    if (!snapshot)
    {
        outError = "timeline has no open snapshot";
        owner_->SetLastError(outError);
        return false;
    }

    std::lock_guard<std::mutex> scrubLock(audioScrubMutex_);
    if (!audioScrub_)
    {
        audioScrub_ = std::make_unique<ScrubAudio>();
    }
    audioScrub_->RenderGrain(*snapshot, frame, direction, outInterleavedStereo);
    return true;
}

void TimelineSession::SetPlayheadCallback(PE_PlayheadCallback callback, void* userCtx)
{
    std::lock_guard<std::mutex> lock(playheadMutex_);
    playheadCallback_ = callback;
    playheadUserCtx_ = userCtx;
}

// --- E4.5 playback / A/V clock (docs/audio-playback-v1.md §3, §4) --------------------------

int64_t TimelineSession::TimelineDurationFrames(const TimelineSnapshot& snapshot)
{
    int64_t end = 0;
    for (const SnapshotTrack& track : snapshot.tracks)
    {
        for (const SnapshotClip& clip : track.clips)
        {
            end = std::max(end, clip.EndFrameExclusive());
        }
        for (const SnapshotTextClip& text : track.textClips)
        {
            end = std::max(end, text.EndFrameExclusive());
        }
    }
    return end;
}

// doc §3.4 trigger 1: is any non-muted "audio"-type track's clip live at `frame`? A muted track's
// clips never count (its contribution is skipped whole), so muting is what hands the clock to QPC.
bool TimelineSession::AnyAudibleAt(const TimelineSnapshot& snapshot, int64_t frame) const
{
    for (const SnapshotTrack& track : snapshot.tracks)
    {
        if (track.type != SnapshotTrackType::Audio || track.muted)
        {
            continue;
        }
        for (const SnapshotClip& clip : track.clips)
        {
            if (clip.ContainsFrame(frame))
            {
                return true;
            }
        }
    }
    return false;
}

void TimelineSession::EnsureAudioEngine()
{
    if (audioEngine_)
    {
        return;
    }
    audioEngine_ = std::make_unique<AudioEngine>();
    audioEngine_->Initialize(); // returns true even with no device (null-device/QPC path, doc §3.4)
    playbackMixer_ = std::make_unique<AudioMixer>();
    audioEngine_->SetFillCallback([this](float* dst, uint32_t frames) { FillAudio(dst, frames); });

    std::lock_guard<std::mutex> clockLock(clockMutex_);
    AudioEngine* engine = audioEngine_.get();
    clock_.SetSamplesReader([engine] { return engine->PlayedSampleFrames(); });
}

// Reset the live-fill cursor + whole-frame staging so the persistent voice resumes from `frame`.
// fillMutex_ is held by the caller (doc §3.3 seek path / a fresh voice Start).
void TimelineSession::SetFillCursorToFrameLocked(int64_t frame)
{
    double fps = 30.0;
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        if (snapshot_)
        {
            fps = snapshot_->Fps();
        }
    }
    const int64_t startSample = static_cast<int64_t>(std::llround(static_cast<double>(frame) * 48000.0 / fps));
    fillCursorSample_ = startSample;
    stagingBaseSample_ = startSample;
    nextRenderFrame_ = frame;
    stagingInterleaved_.clear();
}

// The persistent voice's fill callback — runs on the AudioEngine submit thread (never the XAudio2
// callback thread, so a slow decode here is safe). Drives the live mixer one WHOLE timeline frame
// at a time into a contiguous staging buffer (sample-accurate for integer samples-per-frame, e.g.
// 48 kHz / 30 fps = 1600), then copies the requested block out. Never touches clockMutex_, and any
// decode failure degrades to silence — the clock reads SamplesPlayed regardless of fill content.
// The mix slice (doc §9) owns the mixer routine; this is the infra seam that wires it in.
void TimelineSession::FillAudio(float* dstInterleavedStereo, uint32_t frameCount)
{
    const size_t dstFloats = static_cast<size_t>(frameCount) * 2;
    try
    {
        std::shared_ptr<const TimelineSnapshot> snapshot;
        {
            std::lock_guard<std::mutex> lock(snapshotMutex_);
            snapshot = snapshot_;
        }
        std::lock_guard<std::mutex> fillLock(fillMutex_);
        if (!snapshot || !playbackMixer_)
        {
            std::memset(dstInterleavedStereo, 0, dstFloats * sizeof(float));
            return;
        }

        const double fps = snapshot->Fps();
        const double samplesPerFrame = 48000.0 / (fps > 0.0 ? fps : 30.0);
        const int64_t needEnd = fillCursorSample_ + static_cast<int64_t>(frameCount);

        // Render whole timeline frames until staging covers [fillCursorSample_, needEnd). Successive
        // frames tile [llround(f·spf), llround((f+1)·spf)) with zero cumulative drift for any fps.
        while (stagingBaseSample_ + static_cast<int64_t>(stagingInterleaved_.size() / 2) < needEnd)
        {
            const int64_t f = nextRenderFrame_;
            const int64_t fStart = static_cast<int64_t>(std::llround(static_cast<double>(f) * samplesPerFrame));
            const int64_t fEnd = static_cast<int64_t>(std::llround(static_cast<double>(f + 1) * samplesPerFrame));
            int32_t cnt = static_cast<int32_t>(fEnd - fStart);
            if (cnt <= 0)
            {
                cnt = 1;
            }
            const size_t oldSamples = stagingInterleaved_.size() / 2;
            stagingInterleaved_.resize((oldSamples + static_cast<size_t>(cnt)) * 2);
            std::string err;
            if (!playbackMixer_->RenderRange(*snapshot, f, cnt, stagingInterleaved_.data() + oldSamples * 2, err))
            {
                std::fill(stagingInterleaved_.begin() + static_cast<std::ptrdiff_t>(oldSamples * 2),
                    stagingInterleaved_.end(), 0.0f);
            }
            nextRenderFrame_ = f + 1;
        }

        const int64_t offset = fillCursorSample_ - stagingBaseSample_;
        const int64_t staged = static_cast<int64_t>(stagingInterleaved_.size() / 2);
        for (uint32_t i = 0; i < frameCount; ++i)
        {
            const int64_t idx = offset + static_cast<int64_t>(i);
            if (idx >= 0 && idx < staged)
            {
                dstInterleavedStereo[i * 2] = stagingInterleaved_[static_cast<size_t>(idx) * 2];
                dstInterleavedStereo[i * 2 + 1] = stagingInterleaved_[static_cast<size_t>(idx) * 2 + 1];
            }
            else
            {
                dstInterleavedStereo[i * 2] = 0.0f;
                dstInterleavedStereo[i * 2 + 1] = 0.0f;
            }
        }
        fillCursorSample_ = needEnd;

        // Drop fully-consumed staging to bound memory (keep well under a second).
        const int64_t consumed = fillCursorSample_ - stagingBaseSample_;
        if (consumed > 48000)
        {
            const size_t drop = static_cast<size_t>(consumed);
            stagingInterleaved_.erase(stagingInterleaved_.begin(),
                stagingInterleaved_.begin() + static_cast<std::ptrdiff_t>(drop * 2));
            stagingBaseSample_ += static_cast<int64_t>(drop);
        }
    }
    catch (...)
    {
        std::memset(dstInterleavedStereo, 0, dstFloats * sizeof(float));
    }
}

int32_t TimelineSession::Play()
{
    EnsureAudioEngine();
    {
        std::lock_guard<std::mutex> clockLock(clockMutex_);
        if (isPlaying_.load(std::memory_order_relaxed))
        {
            return PE_OK; // idempotent, mirrors AVPlayer.play()
        }
        const int64_t frame = clock_.CurrentFrame(); // == frozen rebaseFrame (was paused)
        clock_.SetRate(1.0);
        clock_.Rebase(frame, false); // start on the QPC clock; the present tick flips to audio
        isPlaying_.store(true, std::memory_order_relaxed);
    }
    mailboxCv_.notify_one(); // wake the render thread into present mode
    FireIsPlaying(true);
    return PE_OK;
}

int32_t TimelineSession::Pause()
{
    bool wasPlaying;
    {
        std::lock_guard<std::mutex> clockLock(clockMutex_);
        wasPlaying = isPlaying_.load(std::memory_order_relaxed);
        if (wasPlaying)
        {
            const int64_t frame = clock_.CurrentFrame(); // freeze at wherever the clock reached
            clock_.SetRate(0.0);
            clock_.Rebase(frame, false);
            isPlaying_.store(false, std::memory_order_relaxed);
        }
    }
    if (wasPlaying)
    {
        mailboxCv_.notify_one(); // wake the render thread to Stop the voice (doc §3.3 Pause path)
        FireIsPlaying(false);
    }
    return PE_OK; // idempotent
}

int32_t TimelineSession::SetRate(double rate)
{
    // v1 accepts only 0.0 (paused) or 1.0 (playing) — doc §4. PE_TimelineSetRate rejects anything
    // else with PE_ERROR_INVALID_ARGUMENT; the clock math itself is rate-general (video-only rate
    // is a future value change, not an ABI break), gated here.
    if (rate == 1.0)
    {
        return Play();
    }
    if (rate == 0.0)
    {
        return Pause();
    }
    return PE_ERROR_INVALID_ARGUMENT;
}

int32_t TimelineSession::GetClockFrame(int64_t* outFrame)
{
    if (!outFrame)
    {
        return PE_ERROR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> clockLock(clockMutex_);
    *outFrame = clock_.CurrentFrame();
    return PE_OK;
}

bool TimelineSession::DebugUsingAudioClock()
{
    std::lock_guard<std::mutex> clockLock(clockMutex_);
    return clock_.UsingAudioClock();
}

void TimelineSession::SetIsPlayingCallback(PE_IsPlayingCallback callback, void* userCtx)
{
    std::lock_guard<std::mutex> lock(isPlayingCbMutex_);
    isPlayingCallback_ = callback;
    isPlayingUserCtx_ = userCtx;
}

void TimelineSession::FireIsPlaying(bool isPlaying)
{
    std::lock_guard<std::mutex> lock(isPlayingCbMutex_);
    if (isPlayingCallback_)
    {
        isPlayingCallback_(isPlayingUserCtx_, isPlaying ? 1 : 0);
    }
}
