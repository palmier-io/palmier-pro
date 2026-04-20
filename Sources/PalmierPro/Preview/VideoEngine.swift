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

    func seek(to frame: Int) {
        guard let editor else { return }
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(editor.timeline.fps))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
            rebuild()
        case .mediaAsset(let id, _, let type):
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
            seek(to: editor.currentFrame)
            if editor.isPlaying { player.play() }
        }
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
        let fps = editor.timeline.fps
        let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard let editor = self.editor else { return }
                if editor.isPlaying && !editor.isScrubbing {
                    let frame = secondsToFrame(seconds: time.seconds, fps: editor.timeline.fps)
                    if editor.activePreviewTab == .timeline {
                        editor.currentFrame = frame
                    } else {
                        editor.sourcePlayheadFrame = frame
                    }
                }
            }
        }
    }
}
