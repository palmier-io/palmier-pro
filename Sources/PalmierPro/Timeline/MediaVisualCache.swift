import AppKit
import AVFoundation
import DSWaveformImage
import ImageIO

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
        let key = asset.id
        guard waveformSamples[key] == nil, !waveformInFlight.contains(key) else { return }
        waveformInFlight.insert(key)

        let url = asset.url
        Task.detached(priority: .utility) { [weak self] in
            await Self.waveformGate.wait()
            defer { Task { await Self.waveformGate.signal() } }
            let analyzer = WaveformAnalyzer()
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            let count = Self.waveformSampleCount(duration: duration)
            let result = try? await analyzer.samples(fromAudioAt: url, count: count)
            guard let self else { return }
            await MainActor.run { [self] in
                self.waveformInFlight.remove(key)
                if let result {
                    self.waveformSamples[key] = result
                    self.timelineView?.needsDisplay = true
                } else {
                    Log.preview.error("waveform gen FAILED key=\(key.prefix(8)) url=\(url.lastPathComponent)")
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
            await Self.imageThumbnailGate.wait()
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
            var results: [(time: Double, image: CGImage)] = []
            let avAsset = AVURLAsset(url: url)
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
                    }
                }
                results.sort { $0.time < $1.time }
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

    private nonisolated static func waveformSampleCount(duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 4000 }
        if duration >= Double(20_000) / 150 { return 20_000 }
        return max(4000, Int(duration * 150))
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
}
