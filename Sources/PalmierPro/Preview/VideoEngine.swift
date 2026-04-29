import AVFoundation
import AppKit

@Observable
@MainActor
final class VideoEngine {
    private(set) var player = AVPlayer()
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var trackMappings: [TrackMapping] = []
    private var clipNaturalSizes: [String: CGSize] = [:]
    private var compositionDuration: CMTime = .zero
    private var isSeeking = false
    private var pendingSeek: (time: CMTime, tolerance: CMTime)?

    let textController = TextLayerController()
    weak var previewView: PreviewNSView?

    weak var editor: EditorViewModel?

    init(editor: EditorViewModel) {
        self.editor = editor
        setupTimeObserver()
    }

    /// Must be called before discarding this engine (e.g. window close).
    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: - Playback control

    func play() {
        guard let editor else { return }
        editor.isPlaying = true
        guard rebuildTask == nil else { return }
        let frame = editor.activePreviewTab == .timeline ? editor.currentFrame : editor.sourcePlayheadFrame
        seek(to: frame)
        player.play()
    }

    func pause() {
        player.pause()
        editor?.isPlaying = false
    }

    func togglePlayback() {
        if editor?.isPlaying == true { pause() } else { play() }
    }

    func seek(to frame: Int, tolerant: Bool = false) {
        guard let editor else { return }
        textController.tick(frame)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(editor.timeline.fps))
        scheduleSeek(to: time, tolerance: seekTolerance(tolerant: tolerant, editor: editor))
    }

    /// Scaled by active video track count — concurrent decoders need more headroom
    /// to land on a shared I-frame.
    private func seekTolerance(tolerant: Bool, editor: EditorViewModel) -> CMTime {
        guard tolerant else { return .zero }
        let videoTracks = editor.timeline.tracks.filter { $0.type == .video && !$0.clips.isEmpty }.count
        let seconds = 0.5 * Double(max(1, videoTracks))
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Coalesces seeks — AVPlayer can't drain a per-tick queue in real time.
    private func scheduleSeek(to time: CMTime, tolerance: CMTime) {
        if isSeeking {
            pendingSeek = (time, tolerance)
            return
        }
        isSeeking = true
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.scheduleSeek(to: next.time, tolerance: next.tolerance)
                }
            }
        }
    }

    // MARK: - Preview modes

    func previewAsset(_ asset: MediaAsset) {
        let item = AVPlayerItem(url: asset.url)
        player.replaceCurrentItem(with: item)
    }

    func activateTab(_ tab: PreviewTab) {
        guard let editor else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        pause()
        switch tab {
        case .timeline:
            textController.textRoot.isHidden = false
            rebuild()
        case .mediaAsset(let id, _, let type):
            textController.textRoot.isHidden = true
            guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return }
            if type == .image {
                player.replaceCurrentItem(with: nil)
            } else {
                previewAsset(asset)
                seek(to: editor.sourcePlayheadFrame)
            }
        }
    }

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
            player.replaceCurrentItem(with: item)
            syncTextLayers()

            seek(to: editor.currentFrame)
            if editor.isPlaying { player.play() }
        }
    }

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

    /// Update only visual properties (transform, opacity, volume)
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

    // MARK: - Private

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
}
