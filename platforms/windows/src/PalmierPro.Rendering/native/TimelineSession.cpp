#include "TimelineSession.h"
#include "EngineSession.h"
#include "TimelineRegistry.h"
#include "TimelineSnapshotParser.h"
#include "WicImageReader.h"
#include "WicPngWriter.h"

#include <cmath>
#include <cstdio>

namespace
{
    constexpr auto kInteractiveThrottleInterval = std::chrono::milliseconds(33); // ~30 Hz

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
    {
        std::lock_guard<std::mutex> lock(snapshotMutex_);
        snapshot_ = std::make_shared<const TimelineSnapshot>(std::move(parsed));
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
    auto next = std::make_shared<const TimelineSnapshot>(std::move(parsed));
    // Atomic pointer swap: ComposeFrame() takes its own shared_ptr copy of snapshot_
    // under this same mutex before rendering, so a render already past that point keeps
    // the OLD TimelineSnapshot alive via refcount and finishes against it — "in-flight
    // renders finish on the old snapshot," per the plan.
    std::lock_guard<std::mutex> lock(snapshotMutex_);
    snapshot_ = next;
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
    auto next = std::make_shared<const TimelineSnapshot>(std::move(parsed));
    std::lock_guard<std::mutex> lock(snapshotMutex_);
    snapshot_ = next;
    return true;
}

int32_t TimelineSession::Seek(int64_t frame, int32_t mode)
{
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
    for (;;)
    {
        int64_t frame;
        int32_t mode;
        {
            std::unique_lock<std::mutex> lock(mailboxMutex_);
            mailboxCv_.wait(lock, [&] { return stopRequested_ || hasPending_; });
            if (stopRequested_)
            {
                return;
            }
            frame = pendingFrame_;
            mode = pendingMode_;
            hasPending_ = false;
        }

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
        if (!ok)
        {
            continue; // cancelled or unreadable this pass — a newer mailbox item supersedes it
        }

        {
            std::lock_guard<std::mutex> presenterLock(presenterMutex_);
            if (presenter_ && presenter_->IsAttached())
            {
                std::string presentError;
                std::lock_guard<std::recursive_mutex> gfxLock(owner_->GraphicsMutex());
                presenter_->PresentBgra(result.bgra.data(), result.width, result.height, result.strideBytes, presentError);
            }
        }

        std::lock_guard<std::mutex> phLock(playheadMutex_);
        if (playheadCallback_)
        {
            playheadCallback_(playheadUserCtx_, frame);
        }
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

void TimelineSession::SetPlayheadCallback(PE_PlayheadCallback callback, void* userCtx)
{
    std::lock_guard<std::mutex> lock(playheadMutex_);
    playheadCallback_ = callback;
    playheadUserCtx_ = userCtx;
}
