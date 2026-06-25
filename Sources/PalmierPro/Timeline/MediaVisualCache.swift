import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class MediaVisualCache {

    // MARK: - Waveform samples (normalized 0=loud, 1=silence)

    private var waveformSamples: [String: [Float]] = [:]
    private var waveformInFlight: Set<String> = []
    /// Cap concurrent waveform extractions to avoid starving playback.
    private static let waveformGate = AsyncSemaphore(value: 2)

    // MARK: - Video thumbnails (sorted by time)

    private var videoThumbnails: [String: [(time: Double, image: CGImage)]] = [:]
    private var videoThumbnailInFlight: Set<String> = []

    // MARK: - Image thumbnails (single still per asset)

    private var imageThumbnails: [String: CGImage] = [:]
    private var imageThumbnailInFlight: Set<String> = []
    private static let imageThumbnailGate = AsyncSemaphore(value: 4)

    // MARK: - Redraw trigger

    weak var timelineView: NSView?

    // MARK: - Sync lookups (safe for draw calls)

    nonisolated func samples(for mediaRef: String) -> [Float]? {
        MainActor.assumeIsolated { waveformSamples[mediaRef] }
    }

    nonisolated func thumbnails(for mediaRef: String) -> [(time: Double, image: CGImage)]? {
        MainActor.assumeIsolated { videoThumbnails[mediaRef] }
    }

    nonisolated func imageThumbnail(for mediaRef: String) -> CGImage? {
        MainActor.assumeIsolated { imageThumbnails[mediaRef] }
    }

    // MARK: - Async generation

    func generateWaveform(for asset: MediaAsset) {
        guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else { return }
        let key = asset.id
        guard waveformSamples[key] == nil, !waveformInFlight.contains(key) else { return }
        waveformInFlight.insert(key)

        let url = asset.url
        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.loadOrGenerateWaveform(url: url)
            guard let self else { return }
            await MainActor.run { [self] in
                self.waveformInFlight.remove(key)
                if let result {
                    self.waveformSamples[key] = result
                    self.timelineView?.needsDisplay = true
                }
            }
        }
    }

    func generateImageThumbnail(for asset: MediaAsset) {
        let key = asset.id
        guard imageThumbnails[key] == nil, !imageThumbnailInFlight.contains(key) else { return }
        imageThumbnailInFlight.insert(key)

        let url = asset.url
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await Self.imageThumbnailGate.wait()
            } catch {
                await MainActor.run { [weak self] in _ = self?.imageThumbnailInFlight.remove(key) }
                return
            }
            defer { Task { await Self.imageThumbnailGate.signal() } }

            let thumbnail = Self.makeImageThumbnail(url: url)
            guard let self else { return }
            await MainActor.run { [self] in
                self.imageThumbnailInFlight.remove(key)
                if let thumbnail {
                    self.imageThumbnails[key] = thumbnail
                    self.timelineView?.needsDisplay = true
                }
            }
        }
    }

    func generateVideoThumbnails(for asset: MediaAsset) {
        let key = asset.id
        guard videoThumbnails[key] == nil, !videoThumbnailInFlight.contains(key) else { return }
        videoThumbnailInFlight.insert(key)

        let url = asset.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let cacheKey = Self.diskCacheKey(for: url)
            var results = cacheKey.flatMap(Self.loadThumbnails(key:)) ?? []

            if results.isEmpty {
                let avAsset = AVURLAsset(url: url)
                if (try? await avAsset.loadTracks(withMediaType: .video).first) != nil {
                    let duration = (try? await avAsset.load(.duration).seconds) ?? 0
                    let times = Self.videoThumbnailTimes(duration: duration)

                    if !times.isEmpty {
                        let generator = AVAssetImageGenerator(asset: avAsset)
                        generator.maximumSize = CGSize(width: 120, height: 68)
                        generator.appliesPreferredTrackTransform = true
                        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
                        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

                        for await result in generator.images(for: times) {
                            if case .success(requestedTime: let requestedTime, image: let image, actualTime: _) = result {
                                results.append((time: requestedTime.seconds, image: image))
                                // Publish progressively so long videos fill in instead of appearing at the end.
                                if results.count % 50 == 0, let self {
                                    let partial = results
                                    await MainActor.run { [self] in
                                        self.videoThumbnails[key] = partial
                                        self.timelineView?.needsDisplay = true
                                    }
                                }
                            }
                        }
                        results.sort { $0.time < $1.time }
                    }
                }

                if !results.isEmpty, let cacheKey {
                    Self.saveThumbnails(results, key: cacheKey)
                }
            }

            guard let self else { return }
            await MainActor.run { [self] in
                self.videoThumbnailInFlight.remove(key)
                if !results.isEmpty {
                    self.videoThumbnails[key] = results
                    self.timelineView?.needsDisplay = true
                }
            }
        }
    }

    private nonisolated static func makeImageThumbnail(url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    private nonisolated static func loadOrGenerateWaveform(url: URL) async -> [Float]? {
        let cacheKey = diskCacheKey(for: url)
        if let cacheKey, let cached = loadWaveform(key: cacheKey) { return cached }

        do {
            try await waveformGate.wait()
        } catch {
            return nil
        }
        defer { Task { await waveformGate.signal() } }

        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .audio).first) != nil else { return nil }

        guard let samples = try? await WaveformExtractor.peakEnvelope(from: url), !samples.isEmpty else { return nil }
        if let cacheKey { saveWaveform(samples, key: cacheKey) }
        return samples
    }

    private nonisolated static func videoThumbnailTimes(duration: Double) -> [CMTime] {
        guard duration.isFinite, duration > 0 else { return [] }
        let interval = duration < 10 ? 1.0 : 2.0
        var times: [CMTime] = []
        var time = 0.0
        while time < duration {
            times.append(CMTime(seconds: time, preferredTimescale: 600))
            time += interval
        }
        return times
    }

    // MARK: - Disk cache

    nonisolated static let diskCache = DiskCache(named: "MediaVisualCache")

    /// Keyed on path + size + mtime so source edits invalidate the entry.
    private nonisolated static func diskCacheKey(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let seed = "\(url.path)|\(size)|\(mtime.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func loadWaveform(key: String) -> [Float]? {
        let url = diskCache.directory.appendingPathComponent(key + ".waveform2")
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count % 4 == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private nonisolated static func saveWaveform(_ samples: [Float], key: String) {
        let url = diskCache.directory.appendingPathComponent(key + ".waveform2")
        samples.withUnsafeBytes { try? Data($0).write(to: url) }
    }

    private struct ThumbnailCacheMeta: Codable {
        let tileWidth: Int
        let tileHeight: Int
        let columns: Int
        let times: [Double]
    }

    /// Thumbnails persist as one JPEG sprite grid + JSON sidecar; the sidecar is written
    /// last and treated as the marker of a complete entry.
    private nonisolated static func loadThumbnails(key: String) -> [(time: Double, image: CGImage)]? {
        let metaURL = diskCache.directory.appendingPathComponent(key + ".thumbs.json")
        let imageURL = diskCache.directory.appendingPathComponent(key + ".thumbs.jpg")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(ThumbnailCacheMeta.self, from: metaData),
              meta.tileWidth > 0, meta.tileHeight > 0, meta.columns > 0, !meta.times.isEmpty,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              // Decode here on the background task, not lazily at first main-thread draw.
              let sprite = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let rows = (meta.times.count + meta.columns - 1) / meta.columns
        guard sprite.width >= meta.tileWidth * min(meta.columns, meta.times.count),
              sprite.height >= meta.tileHeight * rows else { return nil }
        var out: [(time: Double, image: CGImage)] = []
        out.reserveCapacity(meta.times.count)
        for (i, t) in meta.times.enumerated() {
            let col = i % meta.columns
            let row = i / meta.columns
            let rect = CGRect(x: col * meta.tileWidth, y: row * meta.tileHeight,
                              width: meta.tileWidth, height: meta.tileHeight)
            guard let tile = sprite.cropping(to: rect) else { return nil }
            out.append((time: t, image: tile))
        }
        return out
    }

    private nonisolated static func saveThumbnails(_ thumbs: [(time: Double, image: CGImage)], key: String) {
        guard let first = thumbs.first?.image, first.width > 0, first.height > 0 else { return }
        let tileW = first.width
        let tileH = first.height
        let columns = min(50, thumbs.count)
        let rows = (thumbs.count + columns - 1) / columns
        guard let ctx = CGContext(data: nil, width: tileW * columns, height: tileH * rows,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        for (i, thumb) in thumbs.enumerated() {
            let col = i % columns
            let row = i / columns
            // CGContext origin is bottom-left; sprite row 0 sits at the top to match cropping space.
            let y = (rows - 1 - row) * tileH
            ctx.draw(thumb.image, in: CGRect(x: col * tileW, y: y, width: tileW, height: tileH))
        }
        guard let sprite = ctx.makeImage() else { return }

        let imageURL = diskCache.directory.appendingPathComponent(key + ".thumbs.jpg")
        let metaURL = diskCache.directory.appendingPathComponent(key + ".thumbs.json")
        guard let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, sprite, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        let meta = ThumbnailCacheMeta(tileWidth: tileW, tileHeight: tileH, columns: columns, times: thumbs.map(\.time))
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL)
        }
    }
}
