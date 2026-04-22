import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales images to a max longest edge and re-encodes as JPEG
/// so its more token efficient for agent.
@MainActor
enum ImageEncoder {
    /// Target 3.5 MB
    static let maxBytes = 3_500_000
    /// Internal downsample target.
    static let maxLongestEdge = 1568

    struct Output {
        let data: Data
        let mime: String
    }

    static func encode(url: URL) -> Output? {
        let stamp = fileStamp(url: url)
        if let stamp, let hit = cache[stamp] { return hit }
        let output = passthrough(url: url, stamp: stamp) ?? downscaled(url: url)
        if let output, let stamp {
            if cache.count >= maxCacheEntries { cache.removeAll() }
            cache[stamp] = output
        }
        return output
    }

    /// JPEG-encode an already-decoded `CGImage`. Shared with video frame sampling.
    static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? buffer as Data : nil
    }

    // MARK: - Paths

    private static func passthrough(url: URL, stamp: FileStamp?) -> Output? {
        guard let mime = passthroughMime(url.pathExtension.lowercased()),
              let size = stamp?.size, size <= maxBytes,
              let (w, h) = dimensions(url: url), max(w, h) <= maxLongestEdge,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        return Output(data: data, mime: mime)
    }

    private static func downscaled(url: URL) -> Output? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongestEdge,
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
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
    private static var cache: [FileStamp: Output] = [:]
    private static let maxCacheEntries = 32

    private static func fileStamp(url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return FileStamp(path: url.path, size: size, mtime: mtime)
    }

    // MARK: - Misc

    private static func passthroughMime(_ ext: String) -> String? {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    private static func dimensions(url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}
