#pragma once

#include "include/palmier_engine.h"
#include "Compositor.h"
#include "D3D11Presenter.h"
#include "GpuCompositor.h"
#include "MediaCache.h"
#include "TimelineSnapshot.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

class EngineSession;

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

    void SetPlayheadCallback(PE_PlayheadCallback callback, void* userCtx);

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

    void RenderThreadLoop();
    bool ComposeFrame(int64_t frame, bool interactive, const std::atomic<int32_t>* cancelFlag,
        ComposeResult& outResult, std::string& outError);
    bool ProvideClipFrame(const SnapshotClip& clip, double sourceSeconds, bool interactive,
        const std::atomic<int32_t>* cancelFlag, double timelineFps, DecodedSourceFrame& outFrame,
        std::vector<uint8_t>& scratch);
    void MarkUnprocessable(const std::string& mediaPath);
};
