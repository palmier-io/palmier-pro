#pragma once

#include "include/palmier_engine.h"
#include "MediaSource.h"
#include "D3D11Presenter.h"

#include <d3d11.h>
#include <wrl/client.h>

#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

class TimelineSession;

// Owns every MediaSource opened on it, so a media handle from one session can never
// be resolved through another. lastError_ mirrors the Mac VideoEngine's single-actor
// usage — callers are expected to serialize calls per session (the C# wrapper does).
//
// Also owns the session's D3D11 device (hardware, falling back to WARP — see
// EnsureGraphicsDevice) and its swap-chain presenter. d3dMutex_ serializes every
// ID3D11DeviceContext submission for this session: presenting and resizing, and
// (opportunistically) MediaSource's D3D11VA hw-decode readback. See
// include/palmier_engine.h for the UI-thread/present-thread contract this implements.
//
// Also owns every TimelineSession opened on it (E2's timeline ABI) — see
// OpenTimeline/UpdateTimeline/CloseTimeline/ResolveTimeline. Each TimelineSession shares
// this session's single D3D11 device/context (EnsureGraphicsDeviceShared/GraphicsContext/
// GraphicsMutex) rather than creating its own, so present submission from multiple open
// timelines' render threads still serializes through one mutex. Capped at
// kMaxOpenTimelines with LRU eviction — "per-timeline cache + eviction" per the plan;
// PE_CloseTimeline evicts explicitly regardless of the cap.
class EngineSession
{
public:
    EngineSession() = default;
    // Out-of-line: TimelineSession is only forward-declared here, so the implicit
    // destructor (which must know how to delete unique_ptr<TimelineSession> map entries)
    // has to be defined where TimelineSession.h is fully visible (EngineSession.cpp).
    ~EngineSession();

    int32_t OpenMedia(const std::string& utf8Path, PE_MediaHandle* outMedia);
    int32_t CloseMedia(PE_MediaHandle media);
    MediaSource* Resolve(PE_MediaHandle media);

    int32_t AttachSwapChain(void* swapChainPanelUnknown, int32_t width, int32_t height);
    int32_t ResizeSwapChain(int32_t width, int32_t height);
    int32_t DetachSwapChain();
    int32_t PresentFrameAt(PE_MediaHandle media, double timelineSeconds);
    int32_t RenderFrameToFile(PE_MediaHandle media, double timelineSeconds, const std::string& utf8PngPath);

    int32_t OpenTimeline(const std::string& utf8SnapshotJson, PE_TimelineHandle* outHandle);
    int32_t CloseTimeline(PE_TimelineHandle handle);

    const char* LastErrorMessage() const { return lastError_.c_str(); }
    void SetLastError(std::string message) { lastError_ = std::move(message); }
    void ClearLastError() { lastError_.clear(); }

    // Shared with TimelineSession so every timeline's presenter/hw-decode attempt uses
    // the same single D3D11 device as PE_AttachSwapChain/PE_OpenMedia — see the class
    // comment above.
    ID3D11Device* EnsureGraphicsDeviceShared(std::string& outError) { return EnsureGraphicsDevice(outError); }
    ID3D11DeviceContext* GraphicsContext() { return context_.Get(); }
    // Recursive: GpuCompositor::Compose (held under this lock — see TimelineSession::
    // ComposeFrame) invokes the ClipFrameProvider callback synchronously, which calls back into
    // EnsureGraphicsDeviceShared/this same mutex on the SAME thread (TimelineSession::
    // ProvideClipFrame) — a plain std::mutex would self-deadlock there.
    std::recursive_mutex& GraphicsMutex() { return d3dMutex_; }
    bool IsGraphicsDeviceHardware() const { return deviceIsHardware_; }

private:
    std::mutex mutex_;
    std::unordered_map<MediaSource*, std::unique_ptr<MediaSource>> mediaSources_;
    std::string lastError_;

    std::recursive_mutex d3dMutex_;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    bool deviceIsHardware_ = false;
    std::unique_ptr<D3D11Presenter> presenter_;

    static constexpr size_t kMaxOpenTimelines = 6;
    std::mutex timelinesMutex_;
    std::unordered_map<PE_TimelineHandle, std::unique_ptr<TimelineSession>> timelines_;
    std::list<PE_TimelineHandle> timelineLru_; // front = most recently used

    // Lazily creates device_/context_ on first use (from either OpenMedia or
    // AttachSwapChain, whichever runs first) and caches them for the session's
    // lifetime. Returns nullptr (with outError set) only if both hardware and WARP
    // device creation fail — essentially unreachable on any real Windows install.
    // Skips straight to WARP when PALMIERENGINE_FORCE_WARP is set (see EngineSession.cpp).
    ID3D11Device* EnsureGraphicsDevice(std::string& outError);
};
