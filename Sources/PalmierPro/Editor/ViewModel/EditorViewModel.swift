import AppKit

@Observable
@MainActor
final class PreviewPlayheadState {
    var timelineFrame: Int = 0
    var sourceFrame: Int = 0
}

struct PendingPanelSeed {
    let asset: MediaAsset
    let stored: GenerationInput
}

struct PendingAudioPlacement {
    let startFrame: Int
    let spanSeconds: Double
    let actionName: String
}

@Observable
@MainActor
final class EditorViewModel {

    // MARK: - Persisted state (synced with VideoProject)

    var timelines: [Timeline] {
        didSet { timelineRenderRevision &+= 1 }
    }
    var activeTimelineId: String
    var openTimelineIds: [String]
    @ObservationIgnored var liveViewStates: [String: TimelineViewState] = [:]
    var timelineTabRenameRequest: String?

    /// Active-timeline proxy; assignment routes by id and activates so undo lands on its timeline.
    var timeline: Timeline {
        get { timelines.first(where: { $0.id == activeTimelineId }) ?? timelines[0] }
        set {
            if let i = timelines.firstIndex(where: { $0.id == newValue.id }) {
                timelines[i] = newValue
            } else {
                let i = timelines.firstIndex(where: { $0.id == activeTimelineId }) ?? 0
                let oldId = timelines[i].id
                timelines[i] = newValue
                openTimelineIds = openTimelineIds.map { $0 == oldId ? newValue.id : $0 }
            }
            activeTimelineId = newValue.id
            if !openTimelineIds.contains(newValue.id) { openTimelineIds.append(newValue.id) }
        }
        _modify {
            let i = timelines.firstIndex(where: { $0.id == activeTimelineId }) ?? 0
            yield &timelines[i]
        }
    }
    var mediaManifest = MediaManifest()
    var generationLog = GenerationLog()

    // MARK: - Denoise bake state (session-scoped, keyed by mediaRef)

    var denoiseInFlight: Set<String> = []
    var denoiseFailed: Set<String> = []
    var denoiseBaked: Set<String> = []
    var speechAnalyzingCount: Int = 0
    var speakerRegistry: [SpeakerRegistryEntry] = []
    var multicamGroups: [MulticamSource] = []
    var speakerAssignments: [String: [String: Int]] = [:]
    var speakerIdentifyPhase: String?
    var speakerIdentifyInFlight: Bool { speakerIdentifyPhase != nil }
    var speakerIdentifyError: String?

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

    // MARK: - Tutorial tour

    let tour = TourController()

    // MARK: - Transient UI state

    var currentFrame: Int = 0 {
        didSet { playheadState.timelineFrame = currentFrame }
    }
    var activeFrame: Int { playheadState.timelineFrame }
    var isPlaying: Bool = false
    var selectedClipIds: Set<String> = []
    var isMarqueeSelecting: Bool = false
    var selectedGap: GapSelection?
    var selectedTimelineRange: TimelineRangeSelection?
    var selectedMediaAssetIds: Set<String> = []
    var selectedFolderIds: Set<String> = []
    var selectedTimelineIds: Set<String> = []
    var pendingSwapClipId: String?
    var clipClipboard: [ClipClipboardEntry] = []
    var zoomScale: Double = Defaults.pixelsPerFrame
    var canvasZoom: CGFloat = 1.0 {
        didSet {
            if canvasZoom <= 1.0 { canvasOffset = .zero }
        }
    }
    var canvasOffset: CGSize = .zero
    var timelineVisibleWidth: Double = 0
    var timelineRenderRevision: Int = 0
    /// Live horizontal scroll of the timeline panel, mirrored from AppKit for view-state stash.
    @ObservationIgnored var timelineScrollOffsetX: Double = 0
    var timelineScrollRestoreX: Double?
    var isScrubbing: Bool = false
    var toolMode: ToolMode = .pointer
    var showExportDialog: Bool = false
    var showGenerationPanel: Bool = false {
        didSet { if showGenerationPanel && !oldValue { showMediaPanelMediaTab() } }
    }
    /// AIEditTab input consumed by GenerationView.
    var pendingPanelSeed: PendingPanelSeed?
    var pendingEditReplacementClipId: String?
    var pendingEditTrimmedSource: TrimmedSource?
    var pendingEditAudioPlacement: PendingAudioPlacement?
    /// Clip ids currently awaiting an AI-generated replacement.
    var pendingReplacements: Set<String> = []
    var cropEditingActive: Bool = false
    var chromaKeySamplingClipId: String?
    var cropAspectLock: CropAspectLock = .free
    var previewTabs: [PreviewTab] = [.timeline]
    var activePreviewTabId: String = PreviewTab.timeline.id
    var previewTabHistory: [String] = [PreviewTab.timeline.id]
    var previewTabHistoryIndex: Int = 0
    var sourcePlayheadFrame: Int = 0 {
        didSet { playheadState.sourceFrame = sourcePlayheadFrame }
    }
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

    var mediaAssets: [MediaAsset] = [] {
        didSet {
            mediaAssetsById = Dictionary(mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
    /// O(1) lookup for draw-path callers; rebuilt on any `mediaAssets` mutation.
    private(set) var mediaAssetsById: [String: MediaAsset] = [:]
    var offlineMediaRefs: Set<String> = []
    var unprocessableMediaRefs: Set<String> = []
    var missingMediaRefs: Set<String> = []
    @ObservationIgnored var missingMediaRefreshTask: Task<Void, Never>?
    let mediaVisualCache = MediaVisualCache()
    let searchIndex = SearchIndexCoordinator()
    var projectURL: URL? {
        didSet {
            guard projectURL != oldValue else { return }
            refreshProjectId()
        }
    }
    private(set) var projectId: String?
    private let editorSessionID = UUID().uuidString
    var exportQueueProjectID: String {
        projectId ?? projectURL?.standardizedFileURL.path ?? editorSessionID
    }
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

    var markDeadAir: Bool = {
        UserDefaults.standard.object(forKey: "markDeadAir") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(markDeadAir, forKey: "markDeadAir")
            mediaVisualCache.timelineView?.needsDisplay = true
        }
    }

    var markBeats: Bool = {
        UserDefaults.standard.object(forKey: "markBeats") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(markBeats, forKey: "markBeats")
            mediaVisualCache.timelineView?.needsDisplay = true
        }
    }

    var markSpeakers: Bool = {
        UserDefaults.standard.object(forKey: "markSpeakers") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(markSpeakers, forKey: "markSpeakers")
            syncSpeakerColors()
        }
    }

    // MARK: - Media panel navigation routing

    var mediaPanelOrderedItemIds: [String] = []
    var mediaPanelColumnCount: Int = 1
    var mediaPanelScrollTarget: String?
    var mediaPanelRevealAssetId: String?
    var mediaPanelOpenFolderId: String?
    var mediaPanelCurrentFolderId: String?
    var mediaPanelPasteRequestTick: Int = 0
    var mediaPanelShowMediaTabTick: Int = 0
    var mediaPanelToast: MediaPanelToast?
    @ObservationIgnored var mediaImportTail: Task<MediaImportSummary, Never>?
    @ObservationIgnored var mediaImportSequence: Int = 0
    @ObservationIgnored var pendingManifestMetadataUpdates: [String: MediaAsset] = [:]
    @ObservationIgnored var pendingManifestMetadataFlushTask: Task<Void, Never>?

    func showMediaPanelMediaTab() {
        mediaPanelShowMediaTabTick += 1
        // Refresh offline status when the user opens the media tab, so missing
        // files show as offline even for assets not on the timeline.
        refreshMissingMediaCache()
    }

    init() {
        let first = Timeline()
        timelines = [first]
        activeTimelineId = first.id
        openTimelineIds = [first.id]
        mediaResolver = MediaResolver(
            manifest: { [weak self] in self?.mediaManifest ?? MediaManifest() },
            projectURL: { [weak self] in self?.projectURL }
        )
        agentService.editor = self
        searchIndex.assetsProvider = { [weak self] in self?.mediaAssets ?? [] }
        mediaVisualCache.speech.onAnalyzingCountChange = { [weak self] count in
            self?.speechAnalyzingCount = count
        }

        // Re-check media presence when the app regains focus: a user may have
        // deleted/moved backing files in Finder (or ejected a volume) while we
        // were inactive. `refreshMissingMediaCache` stats off the main thread.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMissingMediaCache() }
        }
    }

    @ObservationIgnored private nonisolated(unsafe) var didBecomeActiveObserver: NSObjectProtocol?

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    // MARK: - Document bridge

    weak var undoManager: UndoManager?
    @ObservationIgnored var onProjectCheckpointRequired: (() -> Void)?
    var isDocumentEdited: Bool = false

    func telemetrySnapshot() -> [String: Any] {
        var mediaCounts: [String: Int] = [:]
        for asset in mediaAssets {
            mediaCounts[asset.type.rawValue, default: 0] += 1
        }
        let clipCount = timeline.tracks.reduce(0) { $0 + $1.clips.count }
        return [
            "projectId": projectId ?? "unknown",
            "tracks": timeline.tracks.count,
            "clips": clipCount,
            "totalFrames": timeline.totalFrames,
            "fps": timeline.fps,
            "media": mediaAssets.count,
            "mediaByType": mediaCounts,
            "offlineMedia": offlineMediaRefs.count,
            "unprocessableMedia": unprocessableMediaRefs.count,
            "generationLogEntries": generationLog.entries.count,
            "agentSessions": agentService.sessions.count
        ]
    }

    func refreshProjectId() {
        projectId = projectURL.flatMap { ProjectRegistry.shared.id(for: $0)?.uuidString }
    }

    func analyticsSnapshot() -> [String: Any] {
        return [
            "project_id": projectId ?? "unknown",
        ]
    }

    func updateTelemetryContext() {
        Telemetry.setExtra(value: telemetrySnapshot(), key: "project")
    }

    /// Preview playback bridge.
    var videoEngine: VideoEngine?

    let audioMeter = AudioMeterHub()

    @ObservationIgnored
    let playheadState = PreviewPlayheadState()

    // MARK: - Project settings

    /// Set when an imported clip's settings differ from the timeline's — drives the dialog.
    var pendingSettingsMismatch: SettingsMismatch?
    /// Deferred clip-addition, executed after the user resolves the mismatch.
    var pendingSettingsContinuation: (@MainActor () -> Void)?

    // MARK: - Playback

    func togglePlayback() {
        if let videoEngine {
            videoEngine.togglePlayback()
        } else {
            isPlaying.toggle()
        }
    }

    func play() {
        if let videoEngine {
            videoEngine.play()
        } else {
            isPlaying = true
        }
    }

    func pause() {
        if let videoEngine {
            videoEngine.pause()
        } else {
            isPlaying = false
        }
    }

    func resumePlayback() {
        if let videoEngine {
            videoEngine.resumePlayback()
        } else {
            isPlaying = true
        }
    }

    func seekToFrame(_ frame: Int, mode: PreviewSeekMode = .exact) {
        let clamped = min(max(0, frame), max(0, timeline.totalFrames))
        if mode == .interactiveScrub {
            playheadState.timelineFrame = clamped
        } else {
            currentFrame = clamped
        }
        videoEngine?.seek(to: clamped, mode: mode)
    }

    // MARK: - Source playback (for preview tabs)

    func seekSourceToFrame(_ frame: Int, mode: PreviewSeekMode = .exact) {
        let clamped = min(max(0, frame), max(0, activePreviewDurationFrames))
        if mode == .interactiveScrub {
            playheadState.sourceFrame = clamped
        } else {
            sourcePlayheadFrame = clamped
        }
        videoEngine?.seek(to: clamped, mode: mode)
    }

    func toggleSourcePlayback() {
        videoEngine?.togglePlayback()
    }

    func stepForward() { seekToFrame(currentFrame + 1, mode: .audibleStepForward) }
    func stepBackward() { seekToFrame(currentFrame - 1, mode: .audibleStepBackward) }
    func skipForward(frames: Int = 5) { seekToFrame(currentFrame + frames, mode: .audibleStepForward) }
    func skipBackward(frames: Int = 5) { seekToFrame(currentFrame - frames, mode: .audibleStepBackward) }

    // MARK: - Shared infrastructure

    /// Per-clip snapshot at drag start, keyed by clip id so multiple clips can be edited in tandem.
    var dragBefore: [String: Clip] = [:]

    /// Whole-timeline snapshot at drag start, for ripple mutations whose per-clip undos can't compose cleanly.
    var preDragTimeline: Timeline?

    /// Debounced commits, keyed "clipId:property".
    var pendingDebouncedCommits: [String: Task<Void, Never>] = [:]

    /// Coalesces rapid rebuild requests so `replaceCurrentItem` doesn't fire per keystroke.
    var pendingRebuildTask: Task<Void, Never>?

    func notifyTimelineChanged(refreshVisuals: Bool = true) {
        guard undoManager?.isUndoRegistrationEnabled ?? true else { return }
        enhancePendingDenoises()
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        if isPlaying {
            videoEngine?.pause()
        }
        if refreshVisuals {
            videoEngine?.refreshVisuals()
        }
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

    /// Places one clip, optionally with linked audio.
    @discardableResult
    func placeClip(
        asset: MediaAsset,
        trackIndex: Int,
        startFrame: Int,
        durationFrames: Int,
        addLinkedAudio: Bool = true,
        linkedAudioTrackIndex: Int? = nil,
        sourceSegment: ClosedRange<Double>? = nil,
        trimStartFrame: Int? = nil,
        trimEndFrame: Int? = nil
    ) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex) else { return [] }
        let targetIsVideo = timeline.tracks[trackIndex].type == .video
        let shouldLink = addLinkedAudio && targetIsVideo && asset.hasAudio
            && (asset.type == .video || asset.type == .sequence)
        let linkGroupId: String? = shouldLink ? UUID().uuidString : nil
        let trimStart = sourceSegment.map { secondsToFrame(seconds: $0.lowerBound, fps: timeline.fps) } ?? 0
        let totalSourceFrames = secondsToFrame(seconds: asset.duration, fps: timeline.fps)

        // sourceSegment (source seconds) and explicit trim frames are mutually exclusive; callers pass one.
        let applyTrim: (inout Clip) -> Void = { clip in
            if sourceSegment != nil {
                // tail trim is what's left after head trim and visible span
                let consumed = Int((Double(durationFrames) * clip.speed).rounded())
                clip.trimStartFrame = trimStart
                clip.trimEndFrame = max(0, totalSourceFrames - trimStart - consumed)
            } else {
                let start = max(0, trimStartFrame ?? 0)
                clip.trimStartFrame = start
                if totalSourceFrames > 0 {
                    // Use actual remaining source for tail trim if not set; clamp to available.
                    let consumed = Int((Double(durationFrames) * clip.speed).rounded())
                    let remainingTail = max(0, totalSourceFrames - start - consumed)
                    clip.trimEndFrame = min(trimEndFrame ?? remainingTail, remainingTail)
                } else if let t = trimEndFrame {
                    clip.trimEndFrame = t
                }
            }
        }

        var clip = Clip(mediaRef: asset.id, mediaType: asset.type, sourceClipType: asset.type, startFrame: startFrame, durationFrames: durationFrames, transform: fitTransform(for: asset))
        clip.linkGroupId = linkGroupId
        applyTrim(&clip)
        timeline.tracks[trackIndex].clips.append(clip)
        sortClips(trackIndex: trackIndex)
        var ids = [clip.id]

        if let gid = linkGroupId {
            let audioTrackIdx = linkedAudioTrackIndex.flatMap { timeline.tracks.indices.contains($0) ? $0 : nil }
                ?? resolveOrCreateAudioTrack(startFrame: startFrame, duration: durationFrames)
            guard timeline.tracks.indices.contains(audioTrackIdx) else { return ids }
            var audioClip = Clip(mediaRef: asset.id, mediaType: .audio, sourceClipType: asset.type, startFrame: startFrame, durationFrames: durationFrames)
            audioClip.linkGroupId = gid
            applyTrim(&audioClip)
            timeline.tracks[audioTrackIdx].clips.append(audioClip)
            sortClips(trackIndex: audioTrackIdx)
            ids.append(audioClip.id)
        }
        return ids
    }

    /// Creates clips sequentially; callers clear the target range first.
    @discardableResult
    func createClips(
        from assets: [MediaAsset],
        trackIndex: Int,
        startFrame: Int,
        addLinkedAudio: Bool = true,
        linkedAudioTrackIndex: Int? = nil,
        segments: [String: ClosedRange<Double>] = [:]
    ) -> [String] {
        var cursor = startFrame
        var clipIds: [String] = []
        for asset in assets {
            let segment = segments[asset.id]
            let durationFrames = clipDurationFrames(for: asset, segment: segment)
            clipIds.append(contentsOf: placeClip(
                asset: asset,
                trackIndex: trackIndex,
                startFrame: cursor,
                durationFrames: durationFrames,
                addLinkedAudio: addLinkedAudio,
                linkedAudioTrackIndex: linkedAudioTrackIndex,
                sourceSegment: segment
            ))
            cursor += durationFrames
        }
        return clipIds
    }

    func clipDurationFrames(for asset: MediaAsset, segment: ClosedRange<Double>?) -> Int {
        let seconds = segment.map { $0.upperBound - $0.lowerBound } ?? asset.duration
        return max(1, secondsToFrame(seconds: seconds, fps: timeline.fps))
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

    func fitTransform(for asset: MediaAsset) -> Transform {
        fitTransform(for: asset, canvasWidth: timeline.width, canvasHeight: timeline.height)
    }

    func fitTransform(for clip: Clip) -> Transform {
        guard let dims = sourceDimensions(for: clip) else { return Transform() }
        return fitTransform(sourceWidth: dims.width, sourceHeight: dims.height)
    }

    func fitTransform(for asset: MediaAsset, canvasWidth: Int, canvasHeight: Int) -> Transform {
        guard let sw = asset.sourceWidth, let sh = asset.sourceHeight else { return Transform() }
        return fitTransform(sourceWidth: sw, sourceHeight: sh, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    func fitTransform(sourceWidth: Int, sourceHeight: Int) -> Transform {
        fitTransform(sourceWidth: sourceWidth, sourceHeight: sourceHeight, canvasWidth: timeline.width, canvasHeight: timeline.height)
    }

    func fitTransform(sourceWidth: Int, sourceHeight: Int, canvasWidth: Int, canvasHeight: Int) -> Transform {
        guard sourceWidth > 0, sourceHeight > 0, canvasWidth > 0, canvasHeight > 0 else { return Transform() }
        let canvasAspect = Double(canvasWidth) / Double(canvasHeight)
        let relativeAspect = (Double(sourceWidth) / Double(sourceHeight)) / canvasAspect
        let sourceAspect = relativeAspect * canvasAspect
        if abs(canvasAspect - sourceAspect) < Defaults.aspectTolerance {
            return Transform()
        }
        if relativeAspect > 1 {
            return Transform(width: 1.0, height: 1.0 / relativeAspect)
        }
        return Transform(width: relativeAspect, height: 1.0)
    }

    func mediaCanvasAspect(for asset: MediaAsset, canvasWidth: Int, canvasHeight: Int) -> Double? {
        guard let sw = asset.sourceWidth, let sh = asset.sourceHeight,
              sw > 0, sh > 0, canvasWidth > 0, canvasHeight > 0 else { return nil }
        let canvasAspect = Double(canvasWidth) / Double(canvasHeight)
        return (Double(sw) / Double(sh)) / canvasAspect
    }

    /// Source pixel dimensions for a clip: asset dims, or the child timeline's for nest carriers.
    func sourceDimensions(for clip: Clip) -> (width: Int, height: Int)? {
        if let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }),
           let sw = asset.sourceWidth, let sh = asset.sourceHeight, sw > 0, sh > 0 {
            return (sw, sh)
        }
        if clip.sourceClipType == .sequence, let child = timeline(for: clip.mediaRef),
           child.width > 0, child.height > 0 {
            return (child.width, child.height)
        }
        return nil
    }

    /// Source aspect ratio relative to canvas; nil when source dimensions are unknown.
    func mediaCanvasAspect(for clip: Clip) -> Double? {
        guard let dims = sourceDimensions(for: clip), timeline.width > 0, timeline.height > 0 else { return nil }
        let canvasAspect = Double(timeline.width) / Double(timeline.height)
        return (Double(dims.width) / Double(dims.height)) / canvasAspect
    }

    func cropFittingAspect(
        for clip: Clip,
        targetPixelAspect target: Double,
        anchorX: Double = 0.5,
        anchorY: Double = 0.5
    ) -> Crop {
        guard let dims = sourceDimensions(for: clip), target > 0 else { return Crop() }
        let sourceAspect = Double(dims.width) / Double(dims.height)
        if abs(sourceAspect - target) < 0.0001 { return Crop() }
        let ax = min(1, max(0, anchorX))
        let ay = min(1, max(0, anchorY))
        if sourceAspect > target {
            let total = 1 - target / sourceAspect
            let left = total * ax
            return Crop(left: left, top: 0, right: total - left, bottom: 0)
        } else {
            let total = 1 - sourceAspect / target
            let top = total * ay
            return Crop(left: 0, top: top, right: 0, bottom: total - top)
        }
    }

    func removeClipInternal(id: String) {
        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { $0.id == id }
        }
        pendingReplacements.remove(id)
    }

}
