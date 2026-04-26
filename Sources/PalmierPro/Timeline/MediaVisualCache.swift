import AppKit
import AVFoundation
import DSWaveformImage

@MainActor
final class MediaVisualCache {

    // MARK: - Waveform samples (normalized 0=loud, 1=silence)

    private var waveformSamples: [String: [Float]] = [:]
    private var waveformInFlight: Set<String> = []
    /// Cap concurrent waveform extractions to avoid starving playback.
    private static let waveformGate = AsyncSemaphore(value: 2)

    // MARK: - Video thumbnails (sorted by time)

    private var videoThumbnails: [String: [(time: Double, image: CGImage)]] = [:]
    private var thumbnailInFlight: Set<String> = []

    // MARK: - Image thumbnails (single still per asset)

    private var imageThumbnails: [String: CGImage] = [:]

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
            let count = min(20_000, max(4000, Int(duration * 150)))
            let result = try? await analyzer.samples(fromAudioAt: url, count: count)
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
        guard imageThumbnails[key] == nil else { return }
        guard let nsImage = NSImage(contentsOf: asset.url),
              let fullImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Downscale to match video thumbnail size (120x68) to avoid storing full-resolution images
        let maxWidth = 120
        let maxHeight = 68
        let scale = min(CGFloat(maxWidth) / CGFloat(fullImage.width), CGFloat(maxHeight) / CGFloat(fullImage.height), 1.0)
        let scaledWidth = Int(CGFloat(fullImage.width) * scale)
        let scaledHeight = Int(CGFloat(fullImage.height) * scale)

        guard let colorSpace = fullImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: scaledWidth, height: scaledHeight,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let scaled = (ctx.draw(fullImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)),
                            ctx.makeImage()).1
        else {
            imageThumbnails[key] = fullImage
            self.timelineView?.needsDisplay = true
            return
        }

        imageThumbnails[key] = scaled
        self.timelineView?.needsDisplay = true
    }

    func generateThumbnails(for asset: MediaAsset, fps: Int) {
        let key = asset.id
        guard videoThumbnails[key] == nil, !thumbnailInFlight.contains(key) else { return }
        thumbnailInFlight.insert(key)

        let url = asset.url
        Task.detached(priority: .userInitiated) { [weak self] in
            var results: [(time: Double, image: CGImage)] = []
            let avAsset = AVURLAsset(url: url)
            let duration = (try? await avAsset.load(.duration).seconds) ?? 0
            guard duration > 0 else { return }

            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.maximumSize = CGSize(width: 120, height: 68)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

            let interval = max(1.0, duration < 10 ? 1.0 : 2.0)
            var t = 0.0
            while t < duration {
                let cmTime = CMTime(seconds: t, preferredTimescale: 600)
                if let cgImage = try? await generator.image(at: cmTime).image {
                    results.append((time: t, image: cgImage))
                }
                t += interval
            }

            guard let self else { return }
            await MainActor.run { [self] in
                self.thumbnailInFlight.remove(key)
                if !results.isEmpty {
                    self.videoThumbnails[key] = results
                    self.timelineView?.needsDisplay = true
                }
            }
        }
    }
}
