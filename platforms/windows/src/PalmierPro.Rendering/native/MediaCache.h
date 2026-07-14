#pragma once

#include "MediaSource.h"

#include <cstdint>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

struct ID3D11Device;

// Per-timeline decoder cache: LRU-capped MediaSource instances keyed by resolved
// mediaPath, shared across every clip in one timeline (a clip revisited frame-to-frame,
// or the same media referenced by two clips, reuses one open MediaSource). Also owns the
// small decoded-frame LRU keyed (MediaSource*, quantized source frame) that keeps
// playhead-local scrubbing cache-warm without redecoding through FFmpeg.
class MediaCache
{
public:
    explicit MediaCache(size_t mediaCapacity = 8, size_t frameCapacity = 32);

    // Returns nullptr (and sets outError) if the file can't be opened. Bumps mediaPath to
    // most-recently-used; evicts the least-recently-used MediaSource (and any of its
    // cached decoded frames) if over capacity.
    MediaSource* Acquire(const std::string& mediaPath, ID3D11Device* sharedDevice, bool deviceIsHardware, std::string& outError);

    void Clear();

    // `interactiveRequest`: an exact-cached entry (approximate=false) satisfies EITHER an exact
    // or an interactive request — it's strictly more correct than any approximate decode of the
    // same frame. An approximate-cached entry (the nearest-preceding-keyframe result of an
    // interactive/scrub decode) satisfies ONLY an interactive request; it must never be served to
    // an exact/settle request, which would silently return stale keyframe content instead of the
    // actually-requested frame.
    bool TryGetFrame(MediaSource* media, int64_t frameKey, bool interactiveRequest, std::vector<uint8_t>& outBgra,
        int32_t& outWidth, int32_t& outHeight, int32_t& outStride);
    // `approximate` must reflect how the frame was decoded (i.e. the `interactive` flag passed to
    // MediaSource::DecodeFrameAtEx) so it's cached under a key TryGetFrame's exact/interactive
    // split can tell apart.
    void PutFrame(MediaSource* media, int64_t frameKey, bool approximate, const uint8_t* bgra, int32_t width, int32_t height, int32_t strideBytes);

private:
    struct FrameKey
    {
        MediaSource* media;
        int64_t frame;
        // Distinguishes a nearest-preceding-keyframe (interactive scrub) decode from a real
        // exact decode of the same (media, frame) — see TryGetFrame/PutFrame comments above.
        bool approximate;
        bool operator==(const FrameKey& o) const
        {
            return media == o.media && frame == o.frame && approximate == o.approximate;
        }
    };
    struct FrameKeyHash
    {
        size_t operator()(const FrameKey& k) const
        {
            return std::hash<void*>()(k.media) ^ (std::hash<int64_t>()(k.frame) << 1) ^ (k.approximate ? 1u : 0u);
        }
    };
    struct FrameEntry
    {
        FrameKey key;
        std::vector<uint8_t> bgra;
        int32_t width = 0, height = 0, stride = 0;
    };

    using MediaList = std::list<std::pair<std::string, std::unique_ptr<MediaSource>>>;
    using FrameList = std::list<FrameEntry>;

    size_t mediaCapacity_;
    size_t frameCapacity_;
    std::mutex mutex_;

    MediaList mediaLru_; // front = most recently used
    std::unordered_map<std::string, MediaList::iterator> mediaIndex_;

    FrameList frameLru_; // front = most recently used
    std::unordered_map<FrameKey, FrameList::iterator, FrameKeyHash> frameIndex_;

    void EvictFramesFor(MediaSource* media);
};
