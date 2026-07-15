#include "EngineSession.h"
#include "TimelineSession.h"
#include "WicPngWriter.h"

#include <cstdlib>

EngineSession::~EngineSession() = default;

namespace
{
    // Lets a WARP-forced smoke test (see SwapChainPresentTests.cs) exercise the WARP
    // presenter path in CI even on a runner whose hardware device creation would
    // otherwise succeed — the plan calls for a WARP-forced subset actually running in CI,
    // not just whichever branch hardware availability happens to take.
    bool ForceWarpRequested()
    {
        char* value = nullptr;
        size_t len = 0;
        if (_dupenv_s(&value, &len, "PALMIERENGINE_FORCE_WARP") != 0 || !value)
        {
            return false;
        }
        bool forced = len > 0 && value[0] != '0';
        free(value);
        return forced;
    }
}

int32_t EngineSession::OpenMedia(const std::string& utf8Path, PE_MediaHandle* outMedia)
{
    auto source = std::make_unique<MediaSource>();

    std::string deviceError;
    ID3D11Device* device = EnsureGraphicsDevice(deviceError);
    // A failed device probe here isn't fatal to OpenMedia — MediaSource simply skips
    // the opportunistic D3D11VA attempt and decodes in software (see MediaSource::Open).
    bool deviceIsHardware = device != nullptr && deviceIsHardware_;

    std::string error;
    if (!source->Open(utf8Path, device, deviceIsHardware, error))
    {
        SetLastError(error);
        return PE_ERROR_FILE_OPEN_FAILED;
    }

    MediaSource* raw = source.get();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        mediaSources_.emplace(raw, std::move(source));
    }
    *outMedia = reinterpret_cast<PE_MediaHandle>(raw);
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::CloseMedia(PE_MediaHandle media)
{
    auto* raw = reinterpret_cast<MediaSource*>(media);
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = mediaSources_.find(raw);
    if (it == mediaSources_.end())
    {
        SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }
    mediaSources_.erase(it);
    return PE_OK;
}

MediaSource* EngineSession::Resolve(PE_MediaHandle media)
{
    auto* raw = reinterpret_cast<MediaSource*>(media);
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = mediaSources_.find(raw);
    return it == mediaSources_.end() ? nullptr : it->second.get();
}

ID3D11Device* EngineSession::EnsureGraphicsDevice(std::string& outError)
{
    std::lock_guard<std::recursive_mutex> lock(d3dMutex_);
    if (device_)
    {
        return device_.Get();
    }

    D3D_FEATURE_LEVEL featureLevel{};
    HRESULT hr = E_FAIL;
    if (!ForceWarpRequested())
    {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
            nullptr, 0, D3D11_SDK_VERSION, &device_, &featureLevel, &context_);
    }
    if (SUCCEEDED(hr))
    {
        deviceIsHardware_ = true;
        return device_.Get();
    }

    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0,
        nullptr, 0, D3D11_SDK_VERSION, &device_, &featureLevel, &context_);
    if (FAILED(hr))
    {
        outError = "D3D11CreateDevice failed (hardware and WARP both failed)";
        return nullptr;
    }
    deviceIsHardware_ = false;
    return device_.Get();
}

int32_t EngineSession::AttachSwapChain(void* swapChainPanelUnknown, int32_t width, int32_t height)
{
    std::string error;
    ID3D11Device* device = EnsureGraphicsDevice(error);
    if (!device)
    {
        SetLastError(error);
        return PE_ERROR_UNKNOWN;
    }

    std::lock_guard<std::recursive_mutex> lock(d3dMutex_);
    if (!presenter_)
    {
        presenter_ = std::make_unique<D3D11Presenter>();
    }
    if (!presenter_->Attach(device_.Get(), context_.Get(), swapChainPanelUnknown, width, height, error))
    {
        SetLastError(error);
        return PE_ERROR_UNKNOWN;
    }
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::ResizeSwapChain(int32_t width, int32_t height)
{
    std::lock_guard<std::recursive_mutex> lock(d3dMutex_);
    if (!presenter_ || !presenter_->IsAttached())
    {
        SetLastError("no swap chain attached");
        return PE_ERROR_INVALID_HANDLE;
    }
    std::string error;
    if (!presenter_->Resize(width, height, error))
    {
        SetLastError(error);
        return PE_ERROR_UNKNOWN;
    }
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::DetachSwapChain()
{
    std::lock_guard<std::recursive_mutex> lock(d3dMutex_);
    if (presenter_)
    {
        presenter_->Detach();
    }
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::PresentFrameAt(PE_MediaHandle media, double timelineSeconds)
{
    MediaSource* m = Resolve(media);
    if (!m)
    {
        SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }

    PE_FrameBuffer frame{};
    std::string error;
    if (!m->DecodeFrameAt(timelineSeconds, frame, error))
    {
        SetLastError(error);
        return PE_ERROR_DECODE_FAILED;
    }

    std::lock_guard<std::recursive_mutex> lock(d3dMutex_);
    if (!presenter_ || !presenter_->IsAttached())
    {
        SetLastError("no swap chain attached");
        return PE_ERROR_INVALID_HANDLE;
    }
    if (!presenter_->PresentBgra(frame.data, frame.width, frame.height, frame.strideBytes, error))
    {
        SetLastError(error);
        return PE_ERROR_UNKNOWN;
    }
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::OpenTimeline(const std::string& utf8SnapshotJson, PE_TimelineHandle* outHandle)
{
    auto session = std::make_unique<TimelineSession>(this);
    std::string error;
    if (!session->Open(utf8SnapshotJson, error))
    {
        SetLastError(error);
        return PE_ERROR_INVALID_ARGUMENT;
    }

    TimelineSession* raw = session.get();
    auto handle = reinterpret_cast<PE_TimelineHandle>(raw);
    {
        std::lock_guard<std::mutex> lock(timelinesMutex_);
        timelines_.emplace(handle, std::move(session));
        timelineLru_.push_front(handle);
        while (timelines_.size() > kMaxOpenTimelines)
        {
            PE_TimelineHandle evict = timelineLru_.back();
            timelineLru_.pop_back();
            timelines_.erase(evict); // destroys the TimelineSession (joins its render thread)
        }
    }
    *outHandle = handle;
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::CloseTimeline(PE_TimelineHandle handle)
{
    std::lock_guard<std::mutex> lock(timelinesMutex_);
    auto it = timelines_.find(handle);
    if (it == timelines_.end())
    {
        SetLastError("invalid timeline handle");
        return PE_ERROR_INVALID_HANDLE;
    }
    timelineLru_.remove(handle);
    timelines_.erase(it);
    ClearLastError();
    return PE_OK;
}

int32_t EngineSession::RenderFrameToFile(PE_MediaHandle media, double timelineSeconds, const std::string& utf8PngPath)
{
    MediaSource* m = Resolve(media);
    if (!m)
    {
        SetLastError("invalid media handle");
        return PE_ERROR_INVALID_HANDLE;
    }

    PE_FrameBuffer frame{};
    std::string error;
    if (!m->DecodeFrameAt(timelineSeconds, frame, error))
    {
        SetLastError(error);
        return PE_ERROR_DECODE_FAILED;
    }

    if (!WicPngWriter::WriteBgraToPng(frame.data, frame.width, frame.height, frame.strideBytes, utf8PngPath, error))
    {
        SetLastError(error);
        return PE_ERROR_ENCODE_FAILED;
    }
    ClearLastError();
    return PE_OK;
}
