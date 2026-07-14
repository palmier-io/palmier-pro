#include "MediaCache.h"

MediaCache::MediaCache(size_t mediaCapacity, size_t frameCapacity)
    : mediaCapacity_(mediaCapacity), frameCapacity_(frameCapacity)
{
}

MediaSource* MediaCache::Acquire(const std::string& mediaPath, ID3D11Device* sharedDevice, bool deviceIsHardware, std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);

    auto found = mediaIndex_.find(mediaPath);
    if (found != mediaIndex_.end())
    {
        // Bump to most-recently-used (move to front).
        mediaLru_.splice(mediaLru_.begin(), mediaLru_, found->second);
        return found->second->second.get();
    }

    auto source = std::make_unique<MediaSource>();
    if (!source->Open(mediaPath, sharedDevice, deviceIsHardware, outError))
    {
        return nullptr;
    }

    mediaLru_.emplace_front(mediaPath, std::move(source));
    mediaIndex_[mediaPath] = mediaLru_.begin();
    MediaSource* raw = mediaLru_.front().second.get();

    while (mediaLru_.size() > mediaCapacity_)
    {
        auto& evicted = mediaLru_.back();
        MediaSource* evictedPtr = evicted.second.get();
        mediaIndex_.erase(evicted.first);
        EvictFramesFor(evictedPtr);
        mediaLru_.pop_back();
    }

    return raw;
}

void MediaCache::EvictFramesFor(MediaSource* media)
{
    for (auto it = frameLru_.begin(); it != frameLru_.end();)
    {
        if (it->key.media == media)
        {
            frameIndex_.erase(it->key);
            it = frameLru_.erase(it);
        }
        else
        {
            ++it;
        }
    }
}

void MediaCache::Clear()
{
    std::lock_guard<std::mutex> lock(mutex_);
    frameLru_.clear();
    frameIndex_.clear();
    mediaLru_.clear();
    mediaIndex_.clear();
}

bool MediaCache::TryGetFrame(MediaSource* media, int64_t frameKey, bool interactiveRequest, std::vector<uint8_t>& outBgra,
    int32_t& outWidth, int32_t& outHeight, int32_t& outStride)
{
    std::lock_guard<std::mutex> lock(mutex_);
    // Prefer an exact-cached entry — it's correct for either request kind. Only fall back to an
    // approximate (nearest-preceding-keyframe) entry when the CALLER is itself interactive; an
    // exact/settle request must never be satisfied by a stale approximate decode.
    auto found = frameIndex_.find(FrameKey{media, frameKey, /*approximate*/ false});
    if (found == frameIndex_.end() && interactiveRequest)
    {
        found = frameIndex_.find(FrameKey{media, frameKey, /*approximate*/ true});
    }
    if (found == frameIndex_.end())
    {
        return false;
    }
    frameLru_.splice(frameLru_.begin(), frameLru_, found->second);
    const FrameEntry& entry = frameLru_.front();
    outBgra = entry.bgra;
    outWidth = entry.width;
    outHeight = entry.height;
    outStride = entry.stride;
    return true;
}

void MediaCache::PutFrame(MediaSource* media, int64_t frameKey, bool approximate, const uint8_t* bgra, int32_t width, int32_t height, int32_t strideBytes)
{
    std::lock_guard<std::mutex> lock(mutex_);
    FrameKey key{media, frameKey, approximate};
    auto found = frameIndex_.find(key);
    if (found != frameIndex_.end())
    {
        frameLru_.splice(frameLru_.begin(), frameLru_, found->second);
        return;
    }

    FrameEntry entry;
    entry.key = key;
    entry.bgra.assign(bgra, bgra + static_cast<size_t>(strideBytes) * height);
    entry.width = width;
    entry.height = height;
    entry.stride = strideBytes;

    frameLru_.emplace_front(std::move(entry));
    frameIndex_[key] = frameLru_.begin();

    while (frameLru_.size() > frameCapacity_)
    {
        frameIndex_.erase(frameLru_.back().key);
        frameLru_.pop_back();
    }
}
