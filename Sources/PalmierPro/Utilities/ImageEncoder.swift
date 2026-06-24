import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales images to a max longest edge and re-encodes as JPEG
/// so its more token efficient for agent.
enum ImageEncoder {
    /// Target 3.5 MB
    static let maxBytes = 3_500_000
    /// Internal downsample target.
    static let maxLongestEdge = 1568

    struct Output: Sendable {
        let data: Data
        let mime: String
    }

    struct ImageMetadata: Sendable {
        let width: Int?
        let height: Int?
        let thumbnail: CGImage?
    }

    static func encode(url: URL) -> Output? {
        let stamp = fileStamp(url: url)
        if let stamp, let hit = cachedOutput(stamp) { return hit }
        let output = passthrough(url: url, stamp: stamp) ?? downscaled(url: url)
        if let output, let stamp { store(output, for: stamp) }
        return output
    }

    /// JPEG-encode an already-decoded `CGImage`. Shared with video frame sampling.
    nonisolated static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? buffer as Data : nil
    }

    nonisolated static func metadata(url: URL, thumbnailMaxPixelSize: Int? = nil) -> ImageMetadata {
        guard let source = imageSource(url: url) else {
            return ImageMetadata(width: nil, height: nil, thumbnail: nil)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let thumbnailImage: CGImage?
        if let thumbnailMaxPixelSize {
            thumbnailImage = makeThumbnail(source: source, maxPixelSize: thumbnailMaxPixelSize)
        } else {
            thumbnailImage = nil
        }
        return ImageMetadata(
            width: props?[kCGImagePropertyPixelWidth] as? Int,
            height: props?[kCGImagePropertyPixelHeight] as? Int,
            thumbnail: thumbnailImage
        )
    }

    nonisolated static func thumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = imageSource(url: url) else { return nil }
        return makeThumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    // MARK: - Paths

    private static func passthrough(url: URL, stamp: FileStamp?) -> Output? {
        let imageMetadata = metadata(url: url)
        guard let mime = sniffedMime(url: url),
              let size = stamp?.size, size <= maxBytes,
              let width = imageMetadata.width,
              let height = imageMetadata.height,
              max(width, height) <= maxLongestEdge,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        return Output(data: data, mime: mime)
    }

    private static func downscaled(url: URL) -> Output? {
        guard let image = thumbnail(url: url, maxPixelSize: maxLongestEdge) else { return nil }
        for quality in [0.85, 0.7, 0.55, 0.4] as [CGFloat] {
            if let data = encodeJPEG(image, quality: quality), data.count <= maxBytes {
                return Output(data: data, mime: "image/jpeg")
            }
        }
        return nil
    }

    // MARK: - Cache

    /// Memoize by path + size + mtime so `apiMessages()`, which runs on every
    /// agent loop iteration, doesn't re-read and re-encode the same images.
    private struct FileStamp: Hashable {
        let path: String
        let size: Int
        let mtime: Date
    }
    private nonisolated(unsafe) static var cache: [FileStamp: Output] = [:]
    private static let cacheLock = NSLock()
    private static let maxCacheEntries = 32

    private static func cachedOutput(_ stamp: FileStamp) -> Output? {
        cacheLock.withLock { cache[stamp] }
    }

    private static func store(_ output: Output, for stamp: FileStamp) {
        cacheLock.withLock {
            if cache.count >= maxCacheEntries { cache.removeAll() }
            cache[stamp] = output
        }
    }

    private static func fileStamp(url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return FileStamp(path: url.path, size: size, mtime: mtime)
    }

    // MARK: - Misc

    /// MIME from the file's real container type (UTI)
    private static func sniffedMime(url: URL) -> String? {
        guard let source = imageSource(url: url),
              let uti = CGImageSourceGetType(source) as String?
        else { return nil }
        switch uti {
        case UTType.png.identifier: return "image/png"
        case UTType.jpeg.identifier: return "image/jpeg"
        case UTType.gif.identifier: return "image/gif"
        case UTType.webP.identifier: return "image/webp"
        default: return nil
        }
    }

    private nonisolated static func imageSource(url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private nonisolated static func makeThumbnail(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
