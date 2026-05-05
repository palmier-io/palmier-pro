import AppKit

@Observable
@MainActor
final class EditorViewModel {

    // MARK: - Persisted state (synced with VideoProject)

    var timeline = Timeline()
    var mediaManifest = MediaManifest()
    var generationLog = GenerationLog()

    // MARK: - Panel focus

    enum FocusedPanel: String {
        case media, preview, inspector, timeline, agent

        var accessibilityID: String { rawValue + "Panel" }

        init?(accessibilityID: String) {
            guard accessibilityID.hasSuffix("Panel") else { return nil }
            self.init(rawValue: String(accessibilityID.dropLast(5)))
        }
    }

    var focusedPanel: FocusedPanel?
    var maximizedPanel: FocusedPanel?

    // MARK: - Transient UI state

    var currentFrame: Int = 0
    var isPlaying: Bool = false
    var selectedClipIds: Set<String> = []
    var selectedMediaAssetIds: Set<String> = []
    var selectedFolderIds: Set<String> = []
    var zoomScale: Double = Defaults.pixelsPerFrame
    var canvasZoom: CGFloat = 1.0 {
        didSet {
            if canvasZoom <= 1.0 { canvasOffset = .zero }
        }
    }
    var canvasOffset: CGSize = .zero
    var timelineVisibleWidth: Double = 0
    var isScrubbing: Bool = false
    var toolMode: ToolMode = .pointer
    var showExportDialog: Bool = false
    var showGenerationPanel: Bool = false
    /// Set by AIEditTab; Consumed by GenerationView
    var pendingEditSource: MediaAsset?
    var pendingEditReplacementClipId: String?
    var pendingEditTrimmedSource: TrimmedSource?
    var pendingRerun: MediaAsset?
    /// Clip ids currently awaiting an AI-generated replacement.
    var pendingReplacements: Set<String> = []
    var showHelp: Bool = false
    var helpTab: HelpTab = .shortcuts
    var cropEditingActive: Bool = false
    var cropAspectLock: CropAspectLock = .free
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

    let generationService = GenerationService()
    let agentService = AgentService()

    var agentPanelVisible: Bool = {
        UserDefaults.standard.object(forKey: "agentPanelVisible") as? Bool ?? false
    }() {
        didSet { UserDefaults.standard.set(agentPanelVisible, forKey: "agentPanelVisible") }
    }

    var mediaPanelVisible: Bool = {
        UserDefaults.standard.object(forKey: "mediaPanelVisible") as? Bool ?? true
    }() {
        didSet { UserDefaults.standard.set(mediaPanelVisible, forKey: "mediaPanelVisible") }
    }

    var inspectorPanelVisible: Bool = {
        UserDefaults.standard.object(forKey: "inspectorPanelVisible") as? Bool ?? true
    }() {
        didSet { UserDefaults.standard.set(inspectorPanelVisible, forKey: "inspectorPanelVisible") }
    }

    var keyframesPanelVisible: Bool = {
        UserDefaults.standard.object(forKey: "keyframesPanelVisible") as? Bool ?? false
    }() {
        didSet { UserDefaults.standard.set(keyframesPanelVisible, forKey: "keyframesPanelVisible") }
    }

    // MARK: - Media panel navigation routing

    var mediaPanelOrderedItemIds: [String] = []
    var mediaPanelColumnCount: Int = 1
    var mediaPanelScrollTarget: String?
    var mediaPanelRevealAssetId: String?
    var mediaPanelOpenFolderId: String?

    init() {
        mediaResolver = MediaResolver(
            manifest: { [weak self] in self?.mediaManifest ?? MediaManifest() },
            projectURL: { [weak self] in self?.projectURL }
        )
        agentService.editor = self
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

    func seekToFrame(_ frame: Int, tolerant: Bool = false) {
        currentFrame = max(0, frame)
        videoEngine?.seek(to: currentFrame, tolerant: tolerant)
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

    /// Per-clip snapshot at drag start, keyed by clip id so multiple clips can be edited in tandem.
    var dragBefore: [String: Clip] = [:]

    /// Whole-timeline snapshot at drag start, for ripple mutations whose per-clip undos can't compose cleanly.
    var preDragTimeline: Timeline?

    /// Debounced commits, keyed "clipId:property".
    var pendingDebouncedCommits: [String: Task<Void, Never>] = [:]

    /// Coalesces rapid rebuild requests so `replaceCurrentItem` doesn't fire per keystroke.
    var pendingRebuildTask: Task<Void, Never>?

    func notifyTimelineChanged() {
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        if isPlaying {
            videoEngine?.pause()
        }
        videoEngine?.syncTextLayers()
        videoEngine?.rebuild()
    }

    /// Coalesce rapid rebuilds. An immediate `notifyTimelineChanged` cancels any pending debounced one.
    func notifyTimelineChangedDebounced(debounce: Duration = .milliseconds(120)) {
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingRebuildTask = nil
            if self.isPlaying { self.videoEngine?.pause() }
            self.videoEngine?.rebuild()
        }
    }

    /// Place one clip at exact frames, optionally pairing the audio from a video
    /// asset onto an audio track. Returns every clip ID created (1 or 2).
    @discardableResult
    func placeClip(
        asset: MediaAsset,
        trackIndex: Int,
        startFrame: Int,
        durationFrames: Int,
        addLinkedAudio: Bool = true,
        linkedAudioTrackIndex: Int? = nil
    ) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex) else { return [] }
        let targetIsVideo = timeline.tracks[trackIndex].type == .video
        let shouldLink = addLinkedAudio && targetIsVideo && asset.type == .video && asset.hasAudio
        let linkGroupId: String? = shouldLink ? UUID().uuidString : nil

        var clip = Clip(mediaRef: asset.id, mediaType: asset.type, sourceClipType: asset.type, startFrame: startFrame, durationFrames: durationFrames, transform: fitTransform(for: asset))
        clip.linkGroupId = linkGroupId
        timeline.tracks[trackIndex].clips.append(clip)
        sortClips(trackIndex: trackIndex)
        var ids = [clip.id]

        if let gid = linkGroupId {
            let audioTrackIdx = linkedAudioTrackIndex.flatMap { timeline.tracks.indices.contains($0) ? $0 : nil }
                ?? resolveOrCreateAudioTrack(startFrame: startFrame, duration: durationFrames)
            guard timeline.tracks.indices.contains(audioTrackIdx) else { return ids }
            var audioClip = Clip(mediaRef: asset.id, mediaType: .audio, sourceClipType: asset.type, startFrame: startFrame, durationFrames: durationFrames)
            audioClip.linkGroupId = gid
            timeline.tracks[audioTrackIdx].clips.append(audioClip)
            sortClips(trackIndex: audioTrackIdx)
            ids.append(audioClip.id)
        }
        return ids
    }

    /// Create clips sequentially at exact frames — callers clear the range first.
    /// Linked audio lands on `linkedAudioTrackIndex`, or `resolveOrCreateAudioTrack` when nil.
    @discardableResult
    func createClips(
        from assets: [MediaAsset],
        trackIndex: Int,
        startFrame: Int,
        addLinkedAudio: Bool = true,
        linkedAudioTrackIndex: Int? = nil
    ) -> [String] {
        var cursor = startFrame
        var clipIds: [String] = []
        for asset in assets {
            let durationFrames = secondsToFrame(seconds: asset.duration, fps: timeline.fps)
            clipIds.append(contentsOf: placeClip(
                asset: asset,
                trackIndex: trackIndex,
                startFrame: cursor,
                durationFrames: durationFrames,
                addLinkedAudio: addLinkedAudio,
                linkedAudioTrackIndex: linkedAudioTrackIndex
            ))
            cursor += durationFrames
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

    func clipFor(id: String) -> Clip? {
        guard let loc = findClip(id: id) else { return nil }
        return timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
    }

    func sortClips(trackIndex: Int) {
        timeline.tracks[trackIndex].clips.sort { $0.startFrame < $1.startFrame }
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

    /// Largest centered crop of `target` aspect (w/h, source pixels) inside the clip's source.
    /// Returns identity crop when source dimensions are unknown or already match.
    func cropFittingAspect(for clip: Clip, targetPixelAspect target: Double) -> Crop {
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }),
              let sw = asset.sourceWidth, let sh = asset.sourceHeight,
              sw > 0, sh > 0, target > 0 else { return Crop() }
        let sourceAspect = Double(sw) / Double(sh)
        if abs(sourceAspect - target) < 0.0001 { return Crop() }
        if sourceAspect > target {
            let visibleWidthFrac = target / sourceAspect
            let inset = (1 - visibleWidthFrac) / 2
            return Crop(left: inset, top: 0, right: inset, bottom: 0)
        } else {
            let visibleHeightFrac = sourceAspect / target
            let inset = (1 - visibleHeightFrac) / 2
            return Crop(left: 0, top: inset, right: 0, bottom: inset)
        }
    }

    func removeClipInternal(id: String) {
        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { $0.id == id }
        }
        pendingReplacements.remove(id)
    }

}
