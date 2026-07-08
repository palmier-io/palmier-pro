import AVFoundation
import AppKit
import CoreImage

enum PreviewSeekMode: String {
    case exact
    case interactiveScrub
}

@MainActor
final class VideoEngine {
    private(set) var player = AVPlayer()

    weak var previewView: PreviewNSView?

    weak var editor: EditorViewModel?

    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?

    private var trackMappings: [TrackMapping] = []
    private var clipNaturalSizes: [String: CGSize] = [:]
    private var resolveTimelineSnapshot: @Sendable (String) -> Timeline? = { _ in nil }
    private var clipTransforms: [String: CGAffineTransform] = [:]
    private var compositionDuration: CMTime = .zero

    private var pendingInteractiveSeek: (time: CMTime, tolerance: CMTime)?
    private var interactiveThrottleTask: Task<Void, Never>?
    private var lastInteractiveDispatchTime: TimeInterval = 0

    init(editor: EditorViewModel) {
        self.editor = editor
        setupTimeObserver()
    }

    func teardown() {
        rebuildTask?.cancel()
        rebuildTask = nil
        compositionCache.removeAll()
        invalidateSeekState()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: - Playback

    func play() {
        guard let editor else { return }
        editor.isPlaying = true
        guard rebuildTask == nil else { return }
        let frame = playbackStartFrame(for: editor)
        seek(to: frame, mode: .exact)
        player.play()
    }

    func pause() {
        editor?.isPlaying = false
        player.pause()
    }

    func resumePlayback() {
        editor?.isPlaying = true
        player.play()
    }

    func togglePlayback() {
        if editor?.isPlaying == true { pause() } else { play() }
    }

    func seek(to frame: Int, mode: PreviewSeekMode = .exact) {
        guard let editor else { return }

        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(editor.timeline.fps))
        let tolerance: CMTime = mode == .interactiveScrub
            ? interactiveTolerance(activeLayerCount: activeVideoLayerCount(at: frame, editor: editor))
            : .zero

        switch mode {
        case .exact:
            cancelInteractiveSeek()
            performSeek(time: time, tolerance: tolerance)
        case .interactiveScrub:
            enqueueInteractiveSeek(time: time, tolerance: tolerance)
        }
    }

    // MARK: - Preview Items

    func previewAsset(_ asset: MediaAsset) {
        if asset.type == .lottie {
            // AVPlayer can't read Lottie JSON — bake (cached) to a playable mov first.
            let url = asset.url, ref = asset.id
            let size = CGSize(width: asset.sourceWidth ?? 512, height: asset.sourceHeight ?? 512)
            let startFrame = editor?.sourcePlayheadFrame ?? 0
            Task { @MainActor [weak self] in
                guard let self, let mov = try? await LottieVideoGenerator.lottieVideo(for: url, mediaRef: ref, size: size) else { return }
                guard case .mediaAsset(let activeId, _, _) = self.editor?.activePreviewTab, activeId == ref else { return }
                self.replacePlayerItem(AVPlayerItem(url: mov), reason: "previewLottie")
                self.seek(to: startFrame, mode: .exact)
            }
            return
        }
        replacePlayerItem(AVPlayerItem(url: asset.url), reason: "previewAsset")
    }

    func activateTab(_ tab: PreviewTab) {
        guard let editor else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        invalidateSeekState()
        pause()

        switch tab {
        case .timeline:
            rebuild()
        case .mediaAsset(let id, _, let type):
            guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return }
            if type == .image {
                replacePlayerItem(nil, reason: "imagePreview")
            } else {
                previewAsset(asset)
                seek(to: editor.sourcePlayheadFrame, mode: .exact)
            }
        }
    }

    private func replacePlayerItem(_ item: AVPlayerItem?, reason: String) {
        invalidateSeekState()
        player.replaceCurrentItem(with: item)
        Log.preview.debug("seek state invalidated reason=\(reason)")
    }

    // MARK: - Composition

    /// Everything CompositionBuilder.build reads; equal inputs → identical composition.
    private struct RebuildInputs: Equatable {
        let involved: [Timeline]  // active timeline plus nested children
        let mediaURLs: [String: URL]
        let assetSizes: [String: CGSize]
        let missingMediaRefs: Set<String>
    }

    func rebuild() {
        guard let editor, editor.activePreviewTab == .timeline else { return }
        rebuildTask?.cancel()

        let mediaURLs = editor.mediaResolver.expectedURLMap()
        let missingMediaRefs = editor.missingMediaRefs
        let assetSizes: [String: CGSize] = Dictionary(
            uniqueKeysWithValues: editor.mediaAssets.compactMap { asset in
                guard let w = asset.sourceWidth, let h = asset.sourceHeight, w > 0, h > 0 else { return nil }
                return (asset.id, CGSize(width: w, height: h))
            }
        )
        let resolveTimeline = editor.timelineResolver()

        let timelineId = editor.timeline.id
        let inputs = RebuildInputs(
            involved: [editor.timeline] + editor.timeline.reachableTimelines(resolve: { editor.timeline(for: $0) }),
            mediaURLs: mediaURLs,
            assetSizes: assetSizes,
            missingMediaRefs: missingMediaRefs
        )
        if let cached = compositionCache[timelineId], cached.inputs == inputs {
            rebuildTask = nil
            apply(cached.result, resolveTimeline: resolveTimeline, editor: editor)
            return
        }

        let snapshot = inputs.involved[0]
        rebuildTask = Task {
            let result: CompositionResult
            do {
                result = try await CompositionBuilder.build(
                    timeline: snapshot,
                    resolveURL: { mediaURLs[$0] },
                    resolveSourceSize: { assetSizes[$0] },
                    resolveTimeline: resolveTimeline,
                    missingMediaRefs: missingMediaRefs,
                    renderSize: CGSize(width: snapshot.width, height: snapshot.height)
                )
            } catch {
                if !Task.isCancelled {
                    Log.preview.error("rebuild failed: \(error.localizedDescription)")
                }
                rebuildTask = nil
                return
            }

            rebuildTask = nil
            guard !Task.isCancelled else { return }

            if result.offlineMediaRefs.isEmpty && result.unprocessableMediaRefs.isEmpty {
                compositionCache[timelineId] = (inputs, result)
            }
            compositionCache = compositionCache.filter { editor.openTimelineIds.contains($0.key) }
            apply(result, resolveTimeline: resolveTimeline, editor: editor)
        }
    }

    private var compositionCache: [String: (inputs: RebuildInputs, result: CompositionResult)] = [:]

    func evictComposition(for timelineId: String) {
        compositionCache.removeValue(forKey: timelineId)
    }

    private func apply(_ result: CompositionResult, resolveTimeline: @escaping @Sendable (String) -> Timeline?, editor: EditorViewModel) {
        trackMappings = result.trackMappings
        clipNaturalSizes = result.clipNaturalSizes
        clipTransforms = result.clipTransforms
        compositionDuration = result.composition.duration
        resolveTimelineSnapshot = resolveTimeline
        editor.offlineMediaRefs = result.offlineMediaRefs
        editor.unprocessableMediaRefs = result.unprocessableMediaRefs

        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        item.videoComposition = result.videoComposition
        replacePlayerItem(item, reason: "rebuild")

        seek(to: editor.currentFrame, mode: .exact)
        if editor.isPlaying { player.play() }
    }

    func refreshVisuals() {
        guard let editor, editor.activePreviewTab == .timeline,
              let currentItem = player.currentItem,
              !trackMappings.isEmpty else {
            rebuild()
            return
        }

        let (audioMix, videoComposition) = CompositionBuilder.buildVisuals(
            timeline: editor.timeline,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes,
            clipTransforms: clipTransforms,
            resolveTimeline: resolveTimelineSnapshot,
            compositionDuration: compositionDuration,
            renderSize: CGSize(width: editor.timeline.width, height: editor.timeline.height)
        )
        currentItem.audioMix = audioMix
        currentItem.videoComposition = videoComposition
    }

    // MARK: - Scopes

    /// Luma + per-channel histogram of the current composited frame (downsampled), normalized 0…1.
    func histogramYRGB(frame: Int? = nil, count: Int = 256) async
        -> (y: [Float], r: [Float], g: [Float], b: [Float])? {
        guard let item = player.currentItem else { return nil }
        let time = frame.flatMap { frame -> CMTime? in
            guard let fps = editor?.timeline.fps, fps > 0 else { return nil }
            return CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        } ?? player.currentTime()
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 320, height: 180)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return Self.histogram(from: cg, count: count)
    }

    /// Normalized luma + RGB bins; luma needs its own pass (per-pixel 709 mix). Testable without a player.
    nonisolated static func histogram(from cg: CGImage, count: Int = 256)
        -> (y: [Float], r: [Float], g: [Float], b: [Float])? {
        let image = CIImage(cgImage: cg)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let ext = CIVector(cgRect: extent)

        func bins(_ img: CIImage) -> [Float] {
            let hist = img.applyingFilter("CIAreaHistogram", parameters: [
                kCIInputExtentKey: ext, "inputScale": 1.0, "inputCount": count,
            ])
            var raw = [Float](repeating: 0, count: count * 4)
            ColorScopes.context.render(
                hist, toBitmap: &raw, rowBytes: count * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: count, height: 1), format: .RGBAf, colorSpace: nil)
            return raw
        }

        // Rec.709 luma collapsed into every channel, so its histogram lives in R.
        let lumaVec = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luma = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": lumaVec, "inputGVector": lumaVec, "inputBVector": lumaVec,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let rgbRaw = bins(image)
        let lumaRaw = bins(luma)

        var y = [Float](repeating: 0, count: count), r = y, g = y, b = y
        var maxV: Float = 0
        for i in 0..<count {
            y[i] = lumaRaw[i * 4]
            r[i] = rgbRaw[i * 4]; g[i] = rgbRaw[i * 4 + 1]; b[i] = rgbRaw[i * 4 + 2]
            maxV = max(maxV, max(y[i], max(r[i], max(g[i], b[i]))))
        }
        if maxV > 0 { for i in 0..<count { y[i] /= maxV; r[i] /= maxV; g[i] /= maxV; b[i] /= maxV } }
        return (y, r, g, b)
    }

    /// Hue distribution of the current composited frame — pixel count per hue bucket, weighted by
    /// saturation so achromatic pixels don't show. Drives the silhouette behind the hue curves.
    func hueHistogram(frame: Int? = nil, count: Int = 96) async -> [Float]? {
        guard let item = player.currentItem else { return nil }
        let time = frame.flatMap { frame -> CMTime? in
            guard let fps = editor?.timeline.fps, fps > 0 else { return nil }
            return CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        } ?? player.currentTime()
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 320, height: 180)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return Self.hueHistogram(from: cg, count: count)
    }

    /// Saturation-weighted hue histogram; sqrt-compressed so small humps stay visible. Testable.
    nonisolated static func hueHistogram(from cg: CGImage, count: Int = 96) -> [Float]? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = px.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bins = [Float](repeating: 0, count: count)
        var i = 0
        while i < px.count {
            let r = Float(px[i]) / 255, g = Float(px[i + 1]) / 255, b = Float(px[i + 2]) / 255
            i += 4
            let mx = max(r, max(g, b)), mn = min(r, min(g, b)), d = mx - mn
            guard d > 1e-4, mx > 1e-4 else { continue }
            var hue: Float = mx == r ? (g - b) / d : (mx == g ? (b - r) / d + 2 : (r - g) / d + 4)
            hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
            bins[min(count - 1, Int(hue * Float(count)))] += d / mx
        }
        var maxV: Float = 0; for v in bins { maxV = max(maxV, v) }
        if maxV > 0 { for j in 0..<count { bins[j] = (bins[j] / maxV).squareRoot() } }
        return bins
    }

    // MARK: - Seek Coordinator

    private func enqueueInteractiveSeek(time: CMTime, tolerance: CMTime) {
        pendingInteractiveSeek = (time, tolerance)
        guard interactiveThrottleTask == nil else { return }

        let elapsed = CACurrentMediaTime() - lastInteractiveDispatchTime
        let delay = max(0, Self.interactiveSeekInterval - elapsed)
        guard delay > 0 else {
            flushPendingInteractiveSeek()
            return
        }

        interactiveThrottleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.interactiveThrottleTask = nil
            self?.flushPendingInteractiveSeek()
        }
    }

    private func flushPendingInteractiveSeek() {
        guard let pending = pendingInteractiveSeek else { return }
        pendingInteractiveSeek = nil
        lastInteractiveDispatchTime = CACurrentMediaTime()
        performSeek(time: pending.time, tolerance: pending.tolerance)
    }

    private func performSeek(time: CMTime, tolerance: CMTime) {
        guard let item = player.currentItem else { return }
        item.cancelPendingSeeks()
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func invalidateSeekState() {
        player.currentItem?.cancelPendingSeeks()
        cancelInteractiveSeek()
        lastInteractiveDispatchTime = 0
    }

    private func cancelInteractiveSeek() {
        interactiveThrottleTask?.cancel()
        interactiveThrottleTask = nil
        pendingInteractiveSeek = nil
    }

    private func interactiveTolerance(activeLayerCount: Int) -> CMTime {
        let seconds = min(0.75, 0.15 * Double(max(1, activeLayerCount)))
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func activeVideoLayerCount(at frame: Int, editor: EditorViewModel) -> Int {
        guard editor.activePreviewTab == .timeline else { return 1 }
        return editor.timeline.tracks.count { track in
            guard track.type == .video, !track.hidden else { return false }
            return track.clips.contains { clip in
                (clip.mediaType == .video || clip.mediaType == .image || clip.mediaType == .sequence)
                    && frame >= clip.startFrame
                    && frame < clip.endFrame
            }
        }
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        guard let editor else { return }
        let interval = CMTime(value: 1, timescale: CMTimeScale(editor.timeline.fps))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let editor = self.editor else { return }
                guard editor.isPlaying, !editor.isScrubbing else { return }

                let frame = secondsToFrame(seconds: time.seconds, fps: editor.timeline.fps)
                let duration = editor.activePreviewDurationFrames
                let clamped = duration > 0 ? min(frame, duration) : frame
                if editor.activePreviewTab == .timeline {
                    editor.currentFrame = clamped
                } else {
                    editor.sourcePlayheadFrame = clamped
                }
                if duration > 0, frame >= duration {
                    self.pause()
                }
            }
        }
    }

    private func playbackStartFrame(for editor: EditorViewModel) -> Int {
        let duration = editor.activePreviewDurationFrames
        guard duration > 0 else { return 0 }
        let current = editor.activePreviewTab == .timeline ? editor.currentFrame : editor.sourcePlayheadFrame
        guard current >= duration else { return current }
        if editor.activePreviewTab == .timeline {
            editor.currentFrame = 0
        } else {
            editor.sourcePlayheadFrame = 0
        }
        return 0
    }

    private static let interactiveSeekInterval: TimeInterval = 1.0 / 30.0
}
