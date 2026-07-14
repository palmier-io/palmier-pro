#pragma once

#include "include/palmier_engine.h"
#include "MediaSource.h"
#include "D3D11Presenter.h"

#include <d3d11.h>
#include <wrl/client.h>

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

// Owns every MediaSource opened on it, so a media handle from one session can never
// be resolved through another. lastError_ mirrors the Mac VideoEngine's single-actor
// usage — callers are expected to serialize calls per session (the C# wrapper does).
//
// Also owns the session's D3D11 device (hardware, falling back to WARP — see
// EnsureGraphicsDevice) and its swap-chain presenter. d3dMutex_ serializes every
// ID3D11DeviceContext submission for this session: presenting and resizing, and
// (opportunistically) MediaSource's D3D11VA hw-decode readback. See
// include/palmier_engine.h for the UI-thread/present-thread contract this implements.
class EngineSession
{
public:
    int32_t OpenMedia(const std::string& utf8Path, PE_MediaHandle* outMedia);
    int32_t CloseMedia(PE_MediaHandle media);
    MediaSource* Resolve(PE_MediaHandle media);

    int32_t AttachSwapChain(void* swapChainPanelUnknown, int32_t width, int32_t height);
    int32_t ResizeSwapChain(int32_t width, int32_t height);
    int32_t DetachSwapChain();
    int32_t PresentFrameAt(PE_MediaHandle media, double timelineSeconds);
    int32_t RenderFrameToFile(PE_MediaHandle media, double timelineSeconds, const std::string& utf8PngPath);

    const char* LastErrorMessage() const { return lastError_.c_str(); }
    void SetLastError(std::string message) { lastError_ = std::move(message); }
    void ClearLastError() { lastError_.clear(); }

private:
    std::mutex mutex_;
    std::unordered_map<MediaSource*, std::unique_ptr<MediaSource>> mediaSources_;
    std::string lastError_;

    std::mutex d3dMutex_;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    bool deviceIsHardware_ = false;
    std::unique_ptr<D3D11Presenter> presenter_;

    // Lazily creates device_/context_ on first use (from either OpenMedia or
    // AttachSwapChain, whichever runs first) and caches them for the session's
    // lifetime. Returns nullptr (with outError set) only if both hardware and WARP
    // device creation fail — essentially unreachable on any real Windows install.
    // Skips straight to WARP when PALMIERENGINE_FORCE_WARP is set (see EngineSession.cpp).
    ID3D11Device* EnsureGraphicsDevice(std::string& outError);
};
