import AVFoundation
import AppKit

enum PreviewSeekMode: String {
    case exact
    case interactiveScrub
}

@MainActor
final class VideoEngine {
    private(set) var player = AVPlayer()

    let textController = TextLayerController()

    weak var previewView: PreviewNSView?

    weak var editor: EditorViewModel?

    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?

    private var trackMappings: [TrackMapping] = []
    private var clipNaturalSizes: [String: CGSize] = [:]
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
        invalidateSeekState()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: - Playback

    func play() {
        guard let editor else { return }
        editor.isPlaying = true
        guard rebuildTask == nil else { return }
        let frame = editor.activePreviewTab == .timeline ? editor.currentFrame : editor.sourcePlayheadFrame
        seek(to: frame, mode: .exact)
        player.play()
    }

    func pause() {
        player.pause()
        editor?.isPlaying = false
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
        textController.tick(frame)

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
            textController.textRoot.isHidden = false
            rebuild()
        case .mediaAsset(let id, _, let type):
            textController.textRoot.isHidden = true
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

    func rebuild() {
        guard let editor, editor.activePreviewTab == .timeline else { return }
        rebuildTask?.cancel()

        let resolver = editor.mediaResolver
        let assetSizes: [String: CGSize] = Dictionary(
            uniqueKeysWithValues: editor.mediaAssets.compactMap { asset in
                guard let w = asset.sourceWidth, let h = asset.sourceHeight, w > 0, h > 0 else { return nil }
                return (asset.id, CGSize(width: w, height: h))
            }
        )

        rebuildTask = Task {
            let result: CompositionResult
            do {
                result = try await CompositionBuilder.build(
                    timeline: editor.timeline,
                    resolveURL: { resolver.resolveURL(for: $0) },
                    resolveSourceSize: { assetSizes[$0] }
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

            trackMappings = result.trackMappings
            clipNaturalSizes = result.clipNaturalSizes
            compositionDuration = result.composition.duration

            let item = AVPlayerItem(asset: result.composition)
            item.audioMix = result.audioMix
            item.videoComposition = result.videoComposition
            replacePlayerItem(item, reason: "rebuild")
            syncTextLayers()

            seek(to: editor.currentFrame, mode: .exact)
            if editor.isPlaying { player.play() }
        }
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
            compositionDuration: compositionDuration
        )
        currentItem.audioMix = audioMix
        currentItem.videoComposition = videoComposition
    }

    // MARK: - Text Layers

    func syncTextLayers() {
        guard let editor, let previewView else { return }
        guard editor.activePreviewTab == .timeline else {
            textController.textRoot.isHidden = true
            return
        }

        textController.textRoot.isHidden = false
        let canvas = CGSize(width: editor.timeline.width, height: editor.timeline.height)
        let videoRect = previewView.playerLayer.videoRect
        let resolvedRect = videoRect.isEmpty ? previewView.bounds : videoRect
        textController.sync(timeline: editor.timeline, canvasSize: canvas, videoRect: resolvedRect)
        textController.tick(editor.currentFrame)
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
                (clip.mediaType == .video || clip.mediaType == .image)
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
                if editor.activePreviewTab == .timeline {
                    editor.currentFrame = frame
                    self.textController.tick(frame)
                } else {
                    editor.sourcePlayheadFrame = frame
                }
            }
        }
    }

    private static let interactiveSeekInterval: TimeInterval = 1.0 / 30.0
}
