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
    private var waveformKeys: [String] = []
    private let maxWaveformAssets = 32
    /// Cap concurrent waveform extractions to avoid starving playback.
    private static let waveformGate = AsyncSemaphore(value: 2)

    // MARK: - Speech masks

    let speech = SpeechMaskStore()
    /// 32 ms cells, value = global speaker id, -1 = none. Session-scoped, set by identifySpeakers.
    var speakerMasks: [String: [Int]] = [:]

    nonisolated func speakerMask(for mediaRef: String) -> [Int]? {
        MainActor.assumeIsolated { speakerMasks[mediaRef] }
    }

    let beats = BeatStore()
    let silenceStore = SilenceStore()

    nonisolated func beatAnalysis(for mediaRef: String) -> BeatAnalysis? {
        beats.analysis(for: mediaRef)
    }

    init() {
        speech.onMaskReady = { [weak self] in self?.timelineView?.needsDisplay = true }
        beats.onBeatsReady = { [weak self] in self?.timelineView?.needsDisplay = true }
    }

    // MARK: - Video thumbnails (sorted by time)

    private var videoThumbnails: [String: [(time: Double, image: CGImage)]] = [:]
    private var videoThumbnailInFlight: Set<String> = []
    private var videoThumbnailKeys: [String] = []
    private let maxVideoThumbnailAssets = 24
    private static let videoThumbnailGate = AsyncSemaphore(value: 2)

    // MARK: - Image thumbnails (single still per asset)

    private var imageThumbnails: [String: CGImage] = [:]
    private var imageThumbnailInFlight: Set<String> = []
    private var imageThumbnailKeys: [String] = []
    private let maxImageThumbnailAssets = 64
    private static let imageThumbnailGate = AsyncSemaphore(value: 4)

    var knownAssetURLs: [String: URL] = [:]

    // MARK: - Stale-result protection

    /// Monotonic per-asset generation; bumped by invalidate/resetSessionState, never cleared.
    @ObservationIgnored private var visualGenerations: [String: Int] = [:]
    @ObservationIgnored private var waveformTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var videoThumbnailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var imageThumbnailTasks: [String: Task<Void, Never>] = [:]

    func startVisualGeneration(key: String) -> Int {
        visualGenerations[key, default: 0] += 1
        return visualGenerations[key]!
    }

    private func canCommitVisual(key: String, url: URL, generation: Int) -> Bool {
        visualGenerations[key] == generation && knownAssetURLs[key] == url
    }

    func commitWaveform(_ samples: [Float]?, key: String, url: URL, generation: Int) -> Bool {
        if visualGenerations[key] == generation {
            waveformTasks[key] = nil
            waveformInFlight.remove(key)
        }
        guard canCommitVisual(key: key, url: url, generation: generation), let samples, !samples.isEmpty else { return false }
        storeWaveform(samples, for: key)
        timelineView?.needsDisplay = true
        return true
    }

    func commitVideoThumbnails(_ thumbs: [(time: Double, image: CGImage)]?, key: String, url: URL, generation: Int) -> Bool {
        if visualGenerations[key] == generation {
            videoThumbnailTasks[key] = nil
            videoThumbnailInFlight.remove(key)
        }
        guard canCommitVisual(key: key, url: url, generation: generation), let thumbs, !thumbs.isEmpty else { return false }
        storeVideoThumbnails(thumbs, for: key)
        timelineView?.needsDisplay = true
        return true
    }

    /// Progressive video results keep the entry in flight; only staleness is checked.
    private func commitPartialVideoThumbnails(_ thumbs: [(time: Double, image: CGImage)], key: String, url: URL, generation: Int) {
        guard canCommitVisual(key: key, url: url, generation: generation) else { return }
        storeVideoThumbnails(thumbs, for: key)
        timelineView?.needsDisplay = true
    }

    func commitImageThumbnail(_ image: CGImage?, key: String, url: URL, generation: Int) -> Bool {
        if visualGenerations[key] == generation {
            imageThumbnailTasks[key] = nil
            imageThumbnailInFlight.remove(key)
        }
        guard canCommitVisual(key: key, url: url, generation: generation), let image else { return false }
        storeImageThumbnail(image, for: key)
        timelineView?.needsDisplay = true
        return true
    }

    private func cancelVisualTasks(for key: String) {
        visualGenerations[key, default: 0] += 1
        waveformTasks[key]?.cancel()
        waveformTasks.removeValue(forKey: key)
        videoThumbnailTasks[key]?.cancel()
        videoThumbnailTasks.removeValue(forKey: key)
        imageThumbnailTasks[key]?.cancel()
        imageThumbnailTasks.removeValue(forKey: key)
    }

    // MARK: - Redraw trigger

    weak var timelineView: NSView?
    var onDeadAirCacheInvalidated: (() -> Void)?

    // MARK: - Sync lookups (safe for draw calls)

    nonisolated func samples(for mediaRef: String) -> [Float]? {
        MainActor.assumeIsolated {
            if let samples = waveformSamples[mediaRef] {
                touchLRU(&waveformKeys, key: mediaRef, limit: maxWaveformAssets) { evicted in
                    waveformSamples.removeValue(forKey: evicted)
                }
                return samples
            }
            if let url = knownAssetURLs[mediaRef], !waveformInFlight.contains(mediaRef) {
                reloadWaveform(key: mediaRef, url: url)
            }
            return nil
        }
    }

    nonisolated func deadAirMask(
        for mediaRef: String,
        settings: SilenceRemovalSettings
    ) -> [Bool]? {
        speech.deadAirMask(for: mediaRef, samples: samples(for: mediaRef), settings: settings)
    }

    nonisolated func quietNonSpeechMask(for mediaRef: String) -> [Bool]? {
        speech.quietNonSpeechMask(for: mediaRef, samples: samples(for: mediaRef))
    }

    nonisolated func thumbnails(for mediaRef: String) -> [(time: Double, image: CGImage)]? {
        MainActor.assumeIsolated {
            if let thumbs = videoThumbnails[mediaRef] {
                touchLRU(&videoThumbnailKeys, key: mediaRef, limit: maxVideoThumbnailAssets) { evicted in
                    videoThumbnails.removeValue(forKey: evicted)
                }
                return thumbs
            }
            if let url = knownAssetURLs[mediaRef], !videoThumbnailInFlight.contains(mediaRef) {
                reloadVideoThumbnails(key: mediaRef, url: url)
            }
            return nil
        }
    }

    nonisolated func imageThumbnail(for mediaRef: String) -> CGImage? {
        MainActor.assumeIsolated {
            if let thumb = imageThumbnails[mediaRef] {
                touchLRU(&imageThumbnailKeys, key: mediaRef, limit: maxImageThumbnailAssets) { evicted in
                    imageThumbnails.removeValue(forKey: evicted)
                }
                return thumb
            }
            if let url = knownAssetURLs[mediaRef], !imageThumbnailInFlight.contains(mediaRef) {
                reloadImageThumbnail(key: mediaRef, url: url)
            }
            return nil
        }
    }

    private func touchLRU(_ keys: inout [String], key: String, limit: Int, onEvict: (String) -> Void) {
        if let idx = keys.firstIndex(of: key) {
            keys.remove(at: idx)
        }
        keys.append(key)
        while keys.count > limit {
            let evicted = keys.removeFirst()
            onEvict(evicted)
        }
    }

    private func storeWaveform(_ samples: [Float], for key: String) {
        waveformSamples[key] = samples
        touchLRU(&waveformKeys, key: key, limit: maxWaveformAssets) { [weak self] evicted in
            self?.waveformSamples.removeValue(forKey: evicted)
        }
    }

    private func storeVideoThumbnails(_ thumbs: [(time: Double, image: CGImage)], for key: String) {
        videoThumbnails[key] = thumbs
        touchLRU(&videoThumbnailKeys, key: key, limit: maxVideoThumbnailAssets) { [weak self] evicted in
            self?.videoThumbnails.removeValue(forKey: evicted)
        }
    }

    private func storeImageThumbnail(_ image: CGImage, for key: String) {
        imageThumbnails[key] = image
        touchLRU(&imageThumbnailKeys, key: key, limit: maxImageThumbnailAssets) { [weak self] evicted in
            self?.imageThumbnails.removeValue(forKey: evicted)
        }
    }

    // MARK: - Async generation

    func generateWaveform(for asset: MediaAsset) {
        guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else { return }
        speech.generate(for: asset)
        beats.hydrate(for: asset)
        knownAssetURLs[asset.id] = asset.url
        reloadWaveform(key: asset.id, url: asset.url)
    }

    private func reloadWaveform(key: String, url: URL) {
        guard waveformSamples[key] == nil, !waveformInFlight.contains(key) else { return }
        waveformInFlight.insert(key)
        let generation = startVisualGeneration(key: key)
        let task = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.loadOrGenerateWaveform(url: url)
            guard let self else { return }
            await MainActor.run { [self] in
                _ = self.commitWaveform(result, key: key, url: url, generation: generation)
            }
        }
        waveformTasks[key] = task
    }

    /// Drops all in-memory state after a disk-cache clear so everything regenerates.
    func resetSessionState() {
        for task in waveformTasks.values { task.cancel() }
        waveformTasks.removeAll()
        for task in videoThumbnailTasks.values { task.cancel() }
        videoThumbnailTasks.removeAll()
        for task in imageThumbnailTasks.values { task.cancel() }
        imageThumbnailTasks.removeAll()
        for key in Array(visualGenerations.keys) { visualGenerations[key, default: 0] += 1 }
        waveformSamples.removeAll()
        waveformKeys.removeAll()
        waveformInFlight.removeAll()
        speakerMasks.removeAll()
        speech.reset()
        beats.reset()
        videoThumbnails.removeAll()
        videoThumbnailKeys.removeAll()
        videoThumbnailInFlight.removeAll()
        imageThumbnails.removeAll()
        imageThumbnailKeys.removeAll()
        imageThumbnailInFlight.removeAll()
        knownAssetURLs.removeAll()
        onDeadAirCacheInvalidated?()
        timelineView?.needsDisplay = true
    }

    /// Clears every cached visual for `mediaRef` so relinked media regenerates.
    func invalidate(_ mediaRef: String) {
        cancelVisualTasks(for: mediaRef)
        waveformSamples.removeValue(forKey: mediaRef)
        waveformKeys.removeAll { $0 == mediaRef }
        waveformInFlight.remove(mediaRef)
        speakerMasks.removeValue(forKey: mediaRef)
        speech.invalidate(mediaRef)
        beats.invalidate(mediaRef)
        videoThumbnails.removeValue(forKey: mediaRef)
        videoThumbnailKeys.removeAll { $0 == mediaRef }
        videoThumbnailInFlight.remove(mediaRef)
        imageThumbnails.removeValue(forKey: mediaRef)
        imageThumbnailKeys.removeAll { $0 == mediaRef }
        imageThumbnailInFlight.remove(mediaRef)
        knownAssetURLs.removeValue(forKey: mediaRef)
        onDeadAirCacheInvalidated?()
    }

    func generateImageThumbnail(for asset: MediaAsset) {
        knownAssetURLs[asset.id] = asset.url
        reloadImageThumbnail(key: asset.id, url: asset.url)
    }

    private func reloadImageThumbnail(key: String, url: URL) {
        guard imageThumbnails[key] == nil, !imageThumbnailInFlight.contains(key) else { return }
        imageThumbnailInFlight.insert(key)
        let generation = startVisualGeneration(key: key)

        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Self.imageThumbnailGate.wait()
            } catch {
                await MainActor.run { [weak self] in _ = self?.commitImageThumbnail(nil, key: key, url: url, generation: generation) }
                return
            }
            defer { Task { await Self.imageThumbnailGate.signal() } }

            let thumbnail = Self.makeImageThumbnail(url: url)
            guard let self else { return }
            await MainActor.run { [self] in
                _ = self.commitImageThumbnail(thumbnail, key: key, url: url, generation: generation)
            }
        }
        imageThumbnailTasks[key] = task
    }

    func generateVideoThumbnails(for asset: MediaAsset) {
        knownAssetURLs[asset.id] = asset.url
        reloadVideoThumbnails(key: asset.id, url: asset.url)
    }

    private func reloadVideoThumbnails(key: String, url: URL) {
        guard videoThumbnails[key] == nil, !videoThumbnailInFlight.contains(key) else { return }
        videoThumbnailInFlight.insert(key)
        let generation = startVisualGeneration(key: key)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Self.videoThumbnailGate.wait()
            } catch {
                await MainActor.run { [weak self] in _ = self?.commitVideoThumbnails(nil, key: key, url: url, generation: generation) }
                return
            }
            defer { Task { await Self.videoThumbnailGate.signal() } }

            var results: [(time: Double, image: CGImage)] = []
            var cacheKey: String?
            let avAsset = AVURLAsset(url: url)
            if (try? await avAsset.loadTracks(withMediaType: .video).first) != nil {
                let duration = (try? await avAsset.load(.duration).seconds) ?? 0
                let times = Self.videoThumbnailTimes(duration: duration)
                // Density is part of the key so an older full-density sprite is never reused.
                cacheKey = times.isEmpty ? nil : Self.diskCacheKey(for: url, thumbnailCount: times.count)
                if let cacheKey {
                    results = Self.loadThumbnails(key: cacheKey) ?? []
                }

                if results.isEmpty, !times.isEmpty {
                    let generator = AVAssetImageGenerator(asset: avAsset)
                    generator.maximumSize = CGSize(width: 120, height: 68)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

                    for await result in generator.images(for: times) {
                        if Task.isCancelled { break }
                        if case .success(requestedTime: let requestedTime, image: let image, actualTime: _) = result {
                            results.append((time: requestedTime.seconds, image: image))
                            // Publish progressively so long videos fill in instead of appearing at the end.
                            if results.count % 50 == 0, let self {
                                let partial = results
                                await MainActor.run { [self] in
                                    self.commitPartialVideoThumbnails(partial, key: key, url: url, generation: generation)
                                }
                            }
                        }
                    }
                    results.sort { $0.time < $1.time }
                }

                if !results.isEmpty, let cacheKey {
                    Self.saveThumbnails(results, key: cacheKey)
                }
            }

            guard let self else { return }
            await MainActor.run { [self] in
                _ = self.commitVideoThumbnails(results.isEmpty ? nil : results, key: key, url: url, generation: generation)
            }
        }
        videoThumbnailTasks[key] = task
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

    /// Cap thumbnails per video so a 2-hour asset can't accumulate thousands of tiles.
    nonisolated static let maxVideoThumbnailsPerAsset = 300

    nonisolated static func videoThumbnailTimes(duration: Double) -> [CMTime] {
        guard duration.isFinite, duration > 0 else { return [] }
        let baseInterval = duration < 10 ? 1.0 : 2.0
        let interval = max(baseInterval, duration / Double(maxVideoThumbnailsPerAsset))
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

    /// Keyed on path + size + mtime so source edits invalidate the entry; thumbnail
    /// density is appended when present so cached sprites of other densities don't reuse.
    nonisolated static func diskCacheKey(for url: URL, thumbnailCount: Int? = nil) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        var seed = "\(url.path)|\(size)|\(mtime.timeIntervalSince1970)"
        if let thumbnailCount { seed += "|\(thumbnailCount)" }
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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        for (i, t) in meta.times.enumerated() {
            let col = i % meta.columns
            let row = i / meta.columns
            let rect = CGRect(x: col * meta.tileWidth, y: row * meta.tileHeight,
                              width: meta.tileWidth, height: meta.tileHeight)
            guard let cropped = sprite.cropping(to: rect) else { return nil }
            guard let tileCtx = CGContext(
                data: nil,
                width: meta.tileWidth,
                height: meta.tileHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { return nil }
            tileCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: meta.tileWidth, height: meta.tileHeight))
            guard let tile = tileCtx.makeImage() else { return nil }
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
