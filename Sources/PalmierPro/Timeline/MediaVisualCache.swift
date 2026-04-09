import AppKit
import AVFoundation
import DSWaveformImage

@MainActor
final class MediaVisualCache {

    // MARK: - Waveform samples (normalized 0=loud, 1=silence)

    private var waveformSamples: [String: [Float]] = [:]
    private var waveformInFlight: Set<String> = []

    // MARK: - Video thumbnails (sorted by time)

    private var videoThumbnails: [String: [(time: Double, image: CGImage)]] = [:]
    private var thumbnailInFlight: Set<String> = []

    // MARK: - Redraw trigger

    weak var timelineView: NSView?

    // MARK: - Sync lookups (safe for draw calls)

    nonisolated func samples(for mediaRef: String) -> [Float]? {
        MainActor.assumeIsolated { waveformSamples[mediaRef] }
    }

    nonisolated func thumbnails(for mediaRef: String) -> [(time: Double, image: CGImage)]? {
        MainActor.assumeIsolated { videoThumbnails[mediaRef] }
    }

    // MARK: - Async generation

    func generateWaveform(for asset: MediaAsset) {
        let key = asset.id
        guard waveformSamples[key] == nil, !waveformInFlight.contains(key) else { return }
        waveformInFlight.insert(key)

        let url = asset.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let analyzer = WaveformAnalyzer()
            let result = try? await analyzer.samples(fromAudioAt: url, count: 4000)
            await MainActor.run {
                guard let self else { return }
                self.waveformInFlight.remove(key)
                if let result {
                    self.waveformSamples[key] = result
                    self.timelineView?.needsDisplay = true
                }
            }
        }
    }

    func generateThumbnails(for asset: MediaAsset, fps: Int) {
        let key = asset.id
        guard videoThumbnails[key] == nil, !thumbnailInFlight.contains(key) else { return }
        thumbnailInFlight.insert(key)

        let url = asset.url
        let duration = asset.duration
        Task.detached(priority: .userInitiated) { [weak self] in
            var results: [(time: Double, image: CGImage)] = []
            let avAsset = AVURLAsset(url: url)
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

            await MainActor.run {
                guard let self else { return }
                self.thumbnailInFlight.remove(key)
                if !results.isEmpty {
                    self.videoThumbnails[key] = results
                    self.timelineView?.needsDisplay = true
                }
            }
        }
    }
}
