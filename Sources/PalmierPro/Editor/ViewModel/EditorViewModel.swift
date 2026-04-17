import AppKit

@Observable
@MainActor
final class EditorViewModel {

    // MARK: - Persisted state (synced with VideoProject)

    var timeline = Timeline()
    var mediaManifest = MediaManifest()

    // MARK: - Panel focus

    enum FocusedPanel: String {
        case media, preview, inspector, timeline

        var accessibilityID: String { rawValue + "Panel" }

        init?(accessibilityID: String) {
            guard accessibilityID.hasSuffix("Panel") else { return nil }
            self.init(rawValue: String(accessibilityID.dropLast(5)))
        }
    }

    var focusedPanel: FocusedPanel?

    // MARK: - Transient UI state

    var currentFrame: Int = 0
    var isPlaying: Bool = false
    var selectedClipIds: Set<String> = []
    var selectedMediaAssetIds: Set<String> = []
    var zoomScale: Double = Defaults.pixelsPerFrame
    var canvasZoom: CGFloat = 1.0
    var timelineVisibleWidth: Double = 0
    var isScrubbing: Bool = false
    var toolMode: ToolMode = .pointer
    var showExportDialog: Bool = false
    var showGenerationPanel: Bool = false
    var showKeyboardShortcuts: Bool = false
    var previewTabs: [PreviewTab] = [.timeline]
    var activePreviewTabId: String = PreviewTab.timeline.id
    var sourcePlayheadFrame: Int = 0
    var layoutPreset: LayoutPreset = {
        if let raw = UserDefaults.standard.string(forKey: "layoutPreset"),
           let preset = LayoutPreset(rawValue: raw) {
            return preset
        }
        return .default
    }() {
        didSet { UserDefaults.standard.set(layoutPreset.rawValue, forKey: "layoutPreset") }
    }

    // MARK: - Media library (in-memory, rebuilt on project open)

    var mediaAssets: [MediaAsset] = []
    let mediaVisualCache = MediaVisualCache()
    var projectURL: URL?
    // Placeholder replaced in init() — @Observable doesn't support lazy var
    private(set) var mediaResolver: MediaResolver = MediaResolver(
        manifest: { MediaManifest() }, projectURL: { nil }
    )

    init() {
        mediaResolver = MediaResolver(
            manifest: { [weak self] in self?.mediaManifest ?? MediaManifest() },
            projectURL: { [weak self] in self?.projectURL }
        )
    }

    // MARK: - Document bridge

    weak var undoManager: UndoManager?
    var isDocumentEdited: Bool = false

    /// Set by PreviewView so timeline scrubbing can seek the player
    var videoEngine: VideoEngine?

    // MARK: - Project settings

    /// Set when an imported clip's settings differ from the timeline's — drives the dialog.
    var pendingSettingsMismatch: SettingsMismatch?
    /// Deferred clip-addition, executed after the user resolves the mismatch.
    var pendingSettingsContinuation: (@MainActor () -> Void)?

    // MARK: - Playback

    func togglePlayback() { isPlaying.toggle() }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func seekToFrame(_ frame: Int) {
        currentFrame = max(0, frame)
        videoEngine?.seek(to: currentFrame)
    }

    // MARK: - Source playback (for preview tabs)

    func seekSourceToFrame(_ frame: Int) {
        sourcePlayheadFrame = max(0, frame)
        videoEngine?.seek(to: sourcePlayheadFrame)
    }

    func toggleSourcePlayback() {
        videoEngine?.togglePlayback()
    }

    func stepForward() { seekToFrame(currentFrame + 1) }
    func stepBackward() { seekToFrame(currentFrame - 1) }
    func skipForward(frames: Int = 5) { seekToFrame(currentFrame + frames) }
    func skipBackward(frames: Int = 5) { seekToFrame(currentFrame - frames) }

    // MARK: - Shared infrastructure

    /// Snapshot captured at drag start for continuous clip edits (speed, property).
    var dragBefore: (clipId: String, clip: Clip)?

    func notifyTimelineChanged() {
        if isPlaying {
            videoEngine?.pause()
        }
        videoEngine?.rebuild()
    }

    /// Create clips from assets sequentially starting at `startFrame`, appending to the given track.
    @discardableResult
    func createClips(
        from assets: [MediaAsset],
        trackIndex: Int,
        startFrame: Int,
        resolveOverlaps: Bool = false
    ) -> [String] {
        var cursor = startFrame
        var clipIds: [String] = []
        for asset in assets {
            let durationFrames = secondsToFrame(seconds: asset.duration, fps: timeline.fps)
            let resolvedStart = resolveOverlaps
                ? resolveOverlap(trackIndex: trackIndex, clipId: "", startFrame: cursor, duration: durationFrames)
                : cursor
            let transform = fitTransform(for: asset)
            let clip = Clip(mediaRef: asset.id, mediaType: asset.type, startFrame: resolvedStart, durationFrames: durationFrames, transform: transform)
            timeline.tracks[trackIndex].clips.append(clip)
            clipIds.append(clip.id)
            cursor = resolvedStart + durationFrames
        }
        return clipIds
    }

    func findClip(id: String) -> ClipLocation? {
        for ti in timeline.tracks.indices {
            if let ci = timeline.tracks[ti].clips.firstIndex(where: { $0.id == id }) {
                return ClipLocation(trackIndex: ti, clipIndex: ci)
            }
        }
        return nil
    }

    func sortClips(trackIndex: Int) {
        timeline.tracks[trackIndex].clips.sort { $0.startFrame < $1.startFrame }
    }

    /// Returns the nearest non-overlapping startFrame for a clip on a track.
    /// Snaps forward to the end of the overlapping clip.
    func resolveOverlap(trackIndex: Int, clipId: String, startFrame: Int, duration: Int) -> Int {
        let others = timeline.tracks[trackIndex].clips.filter { $0.id != clipId }
        var frame = startFrame
        var changed = true
        while changed {
            changed = false
            for other in others {
                let overlapStart = max(frame, other.startFrame)
                let overlapEnd = min(frame + duration, other.endFrame)
                if overlapStart < overlapEnd {
                    frame = other.endFrame
                    changed = true
                }
            }
        }
        return frame
    }

    /// Transform that letterboxes the asset into the canvas, preserving aspect ratio.
    /// Returns the identity transform when source dimensions match the canvas or are unknown.
    private func fitTransform(for asset: MediaAsset) -> Transform {
        guard let sw = asset.sourceWidth, let sh = asset.sourceHeight, sw > 0, sh > 0 else {
            return Transform()
        }
        let canvasAspect = Double(timeline.width) / Double(timeline.height)
        let sourceAspect = Double(sw) / Double(sh)
        if abs(canvasAspect - sourceAspect) < Defaults.aspectTolerance {
            return Transform()
        }
        let scaleW: Double
        let scaleH: Double
        if sourceAspect > canvasAspect {
            scaleW = 1.0
            scaleH = canvasAspect / sourceAspect
        } else {
            scaleW = sourceAspect / canvasAspect
            scaleH = 1.0
        }
        return Transform(topLeft: (0, 0), width: scaleW, height: scaleH)
    }

    /// Source aspect ratio relative to canvas; nil when source dimensions are unknown.
    func mediaCanvasAspect(for clip: Clip) -> Double? {
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }),
              let sw = asset.sourceWidth, let sh = asset.sourceHeight,
              sw > 0, sh > 0 else { return nil }
        let canvasAspect = Double(timeline.width) / Double(timeline.height)
        return (Double(sw) / Double(sh)) / canvasAspect
    }

    func removeClipInternal(id: String) {
        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { $0.id == id }
        }
    }

}
