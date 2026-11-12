import CoreGraphics
import Foundation

/// In-memory LRU cache of rendered HTML/HyperFrames frames for real-time scrub and preview.
/// Thread-safe, bounded capacity to avoid runaway memory during long composition exports.
actor HybridFrameCache {
    static let shared = HybridFrameCache()

    private final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private var cache = NSCache<NSString, Box>()
    private var accessOrder: [NSString] = []
    private let maxEntries: Int

    init(maxEntries: Int = 256) {
        self.maxEntries = maxEntries
        self.cache.countLimit = maxEntries
    }

    /// Generates a cache key for a given template content hash, frame number, and dimensions.
    static func makeKey(contentHash: Int, frame: Int, width: Int, height: Int) -> NSString {
        "\(contentHash)_\(frame)_\(width)x\(height)" as NSString
    }

    /// Retrieves a cached frame if available.
    func frame(contentHash: Int, frame: Int, width: Int, height: Int) -> CGImage? {
        let key = Self.makeKey(contentHash: contentHash, frame: frame, width: width, height: height)
        return cache.object(forKey: key)?.image
    }

    /// Stores a rendered frame in the cache.
    func store(_ image: CGImage, contentHash: Int, frame: Int, width: Int, height: Int) {
        let key = Self.makeKey(contentHash: contentHash, frame: frame, width: width, height: height)
        cache.setObject(Box(image), forKey: key)
    }

    /// Clears cached frames for a specific content hash.
    func invalidate(contentHash: Int) {
        cache.removeAllObjects()
    }

    /// Clears the entire cache.
    func reset() {
        cache.removeAllObjects()
    }
}

