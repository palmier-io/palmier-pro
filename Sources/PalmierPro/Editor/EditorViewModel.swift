import AppKit

@Observable
@MainActor
final class EditorViewModel {

    // MARK: - Persisted state (synced with VideoProject)

    var timeline = Timeline()
    var mediaManifest = MediaManifest()

    // MARK: - Transient UI state

    var currentFrame: Int = 0
    var isPlaying: Bool = false
    var selectedClipIds: Set<String> = []
    var selectedMediaAssetIds: Set<String> = []
    var zoomScale: Double = Defaults.pixelsPerFrame
    var isScrubbing: Bool = false
    var toolMode: ToolMode = .pointer
    var showExportDialog: Bool = false
    var previewTabs: [PreviewTab] = [.timeline]
    var activePreviewTabId: String = PreviewTab.timeline.id
    var sourcePlayheadFrame: Int = 0

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

    // MARK: - Media import

    func importMediaAsset(_ asset: MediaAsset) {
        mediaAssets.append(asset)
        let entry = asset.toManifestEntry(projectURL: projectURL)
        mediaManifest.entries.append(entry)
    }

    func updateManifestDuration(for asset: MediaAsset) {
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
            mediaManifest.entries[idx].duration = asset.duration
        }
    }

    // MARK: - Preview tabs

    var activePreviewTab: PreviewTab {
        previewTabs.first { $0.id == activePreviewTabId } ?? .timeline
    }

    var activePreviewDurationFrames: Int {
        switch activePreviewTab {
        case .timeline:
            return timeline.totalFrames
        case .mediaAsset(let id, _, _):
            guard let asset = mediaAssets.first(where: { $0.id == id }) else { return 0 }
            return secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        }
    }

    func openPreviewTab(for asset: MediaAsset) {
        let tab = PreviewTab.mediaAsset(id: asset.id, name: asset.name, type: asset.type)
        if !previewTabs.contains(where: { $0.id == tab.id }) {
            previewTabs.append(tab)
        }
        activePreviewTabId = tab.id
        sourcePlayheadFrame = 0
        videoEngine?.activateTab(tab)
    }

    func closePreviewTab(id: String) {
        guard id != PreviewTab.timeline.id else { return }
        previewTabs.removeAll { $0.id == id }
        if activePreviewTabId == id {
            activePreviewTabId = PreviewTab.timeline.id
            videoEngine?.activateTab(.timeline)
        }
    }

    func selectPreviewTab(id: String) {
        guard previewTabs.contains(where: { $0.id == id }),
              activePreviewTabId != id else { return }
        activePreviewTabId = id
        videoEngine?.activateTab(activePreviewTab)
    }

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

    // MARK: - Track mutations

    func addTrack(type: ClipType, label: String) {
        let track = Track(type: type, label: label)
        timeline.tracks.append(track)
        undoManager?.registerUndo(withTarget: self) { $0.removeTrack(id: track.id) }
        undoManager?.setActionName("Add Track")
    }

    @discardableResult
    func insertTrack(at index: Int, type: ClipType, label: String) -> Int {
        let track = Track(type: type, label: label)
        let clamped = min(index, timeline.tracks.count)
        timeline.tracks.insert(track, at: clamped)
        undoManager?.registerUndo(withTarget: self) { $0.removeTrack(id: track.id) }
        undoManager?.setActionName("Add Track")
        return clamped
    }

    func moveClipToNewTrack(clipId: String, insertAt: Int, clipType: ClipType, toFrame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        undoManager?.beginUndoGrouping()
        let newIndex = insertTrack(at: insertAt, type: clipType, label: clipType.trackLabel)
        // If we inserted before/at the clip's current track, its index shifted by 1
        let adjustedOriginal = newIndex <= loc.trackIndex ? loc.trackIndex + 1 : loc.trackIndex
        // Move clip directly: remove from old track, add to new
        var clip = timeline.tracks[adjustedOriginal].clips.remove(at: loc.clipIndex)
        clip.startFrame = max(0, toFrame)
        timeline.tracks[newIndex].clips.append(clip)
        sortClips(trackIndex: adjustedOriginal)
        sortClips(trackIndex: newIndex)
        let prevTrack = adjustedOriginal
        let prevFrame = timeline.tracks[newIndex].clips.first(where: { $0.id == clipId })?.startFrame ?? toFrame
        undoManager?.registerUndo(withTarget: self) { $0.moveClip(clipId: clipId, toTrack: prevTrack, toFrame: prevFrame) }
        pruneEmptyTracks()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Move Clip to New Track")
        notifyTimelineChanged()
    }

    func addClips(assets: [MediaAsset], trackIndex: Int, startFrame: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        undoManager?.beginUndoGrouping()
        let clipIds = createClips(from: assets, trackIndex: trackIndex, startFrame: startFrame, resolveOverlaps: true)
        sortClips(trackIndex: trackIndex)
        undoManager?.registerUndo(withTarget: self) { $0.removeClips(ids: Set(clipIds)) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Add Clips")
        notifyTimelineChanged()
    }

    func addClipsToNewTrack(assets: [MediaAsset], insertAt: Int, startFrame: Int) {
        guard let firstAsset = assets.first else { return }
        let trackType = firstAsset.type.isVisual ? ClipType.video : firstAsset.type
        undoManager?.beginUndoGrouping()
        let newIndex = insertTrack(at: insertAt, type: trackType, label: trackType.trackLabel)
        addClips(assets: assets, trackIndex: newIndex, startFrame: startFrame)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Add Clips to New Track")
    }

    func removeTrack(id: String) {
        guard let idx = timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        let removed = timeline.tracks.remove(at: idx)
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.timeline.tracks.insert(removed, at: min(idx, vm.timeline.tracks.count))
            vm.undoManager?.setActionName("Add Track")
        }
        undoManager?.setActionName("Remove Track")
    }

    func toggleTrackMute(trackIndex: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let was = timeline.tracks[trackIndex].muted
        timeline.tracks[trackIndex].muted.toggle()
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.timeline.tracks[trackIndex].muted = was
        }
        undoManager?.setActionName(was ? "Unmute Track" : "Mute Track")
        notifyTimelineChanged()
    }

    func toggleTrackHidden(trackIndex: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let was = timeline.tracks[trackIndex].hidden
        timeline.tracks[trackIndex].hidden.toggle()
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.timeline.tracks[trackIndex].hidden = was
        }
        undoManager?.setActionName(was ? "Show Track" : "Hide Track")
        notifyTimelineChanged()
    }

    func setTrackHeight(trackIndex: Int, height: CGFloat) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let prev = timeline.tracks[trackIndex].displayHeight
        timeline.tracks[trackIndex].displayHeight = max(TrackSize.minHeight, min(TrackSize.maxHeight, height))
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setTrackHeight(trackIndex: trackIndex, height: prev)
        }
        undoManager?.setActionName("Resize Track")
    }

    private func notifyTimelineChanged() {
        if isPlaying {
            videoEngine?.pause()
        }
        videoEngine?.rebuild()
    }

    // MARK: - Clip mutations

    func moveClip(clipId: String, toTrack: Int, toFrame: Int) {
        guard let loc = findClip(id: clipId),
              timeline.tracks.indices.contains(toTrack) else { return }
        // Don't allow moving to a track of a different type
        let clipType = timeline.tracks[loc.trackIndex].type
        guard timeline.tracks[toTrack].type.isCompatible(with: clipType) else { return }
        undoManager?.beginUndoGrouping()
        let prev = (track: loc.trackIndex, frame: timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame)
        var clip = timeline.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
        let resolvedFrame = resolveOverlap(trackIndex: toTrack, clipId: clipId, startFrame: toFrame, duration: clip.durationFrames)
        clip.startFrame = resolvedFrame
        timeline.tracks[toTrack].clips.append(clip)
        sortClips(trackIndex: loc.trackIndex)
        sortClips(trackIndex: toTrack)
        undoManager?.registerUndo(withTarget: self) { $0.moveClip(clipId: clipId, toTrack: prev.track, toFrame: prev.frame) }
        pruneEmptyTracks()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Move Clip")
        notifyTimelineChanged()
    }

    /// Batch-move multiple clips in a single undo group.
    /// Clamps the group delta so no moved clip overlaps a non-moved clip on the same track.
    func moveClips(_ moves: [(clipId: String, toTrack: Int, toFrame: Int)]) {
        undoManager?.beginUndoGrouping()
        let movedIds = Set(moves.map(\.clipId))
        var undoMoves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        var clipInfos: [(clip: Clip, fromTrack: Int, toTrack: Int, toFrame: Int)] = []
        for m in moves {
            guard let loc = findClip(id: m.clipId) else { continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            undoMoves.append((m.clipId, loc.trackIndex, clip.startFrame))
            clipInfos.append((clip, loc.trackIndex, m.toTrack, m.toFrame))
        }
        // Find most restrictive delta clamp across all moved clips vs non-moved obstacles
        var clampedDelta: Int? = nil
        let byDestTrack = Dictionary(grouping: clipInfos, by: \.toTrack)
        for (destTrack, group) in byDestTrack {
            guard timeline.tracks.indices.contains(destTrack) else { continue }
            let obstacles = timeline.tracks[destTrack].clips.filter { !movedIds.contains($0.id) }
            for info in group {
                let proposedStart = max(0, info.toFrame)
                let proposedEnd = proposedStart + info.clip.durationFrames
                for obs in obstacles where proposedStart < obs.endFrame && proposedEnd > obs.startFrame {
                    let origDelta = info.toFrame - info.clip.startFrame
                    let allowedDelta = origDelta < 0
                        ? obs.endFrame - info.clip.startFrame
                        : (obs.startFrame - info.clip.durationFrames) - info.clip.startFrame
                    if clampedDelta == nil || abs(allowedDelta) < abs(clampedDelta!) {
                        clampedDelta = allowedDelta
                    }
                }
            }
        }
        let finalInfos = clampedDelta.map { clamped in
            clipInfos.map { ($0.clip, $0.fromTrack, $0.toTrack, $0.clip.startFrame + clamped) }
        } ?? clipInfos
        for info in finalInfos {
            if let loc = findClip(id: info.clip.id) {
                timeline.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
            }
        }
        for info in finalInfos {
            guard timeline.tracks.indices.contains(info.toTrack) else { continue }
            var clip = info.clip
            clip.startFrame = max(0, info.toFrame)
            timeline.tracks[info.toTrack].clips.append(clip)
        }
        for i in timeline.tracks.indices { sortClips(trackIndex: i) }
        undoManager?.registerUndo(withTarget: self) { $0.moveClips(undoMoves) }
        pruneEmptyTracks()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Move Clips")
        notifyTimelineChanged()
    }

    /// Ripple trim: trims the clip and shifts adjacent clips to stay contiguous.
    /// Only ripples clips that are touching — gaps are preserved.
    func trimClip(clipId: String, trimStartFrame: Int, trimEndFrame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        let ti = loc.trackIndex
        let clip = timeline.tracks[ti].clips[loc.clipIndex]
        let prevStart = clip.trimStartFrame
        let prevEnd = clip.trimEndFrame
        let prevDuration = clip.durationFrames
        let oldEnd = clip.startFrame + clip.durationFrames

        let deltaStart = trimStartFrame - prevStart
        timeline.tracks[ti].clips[loc.clipIndex].trimStartFrame = trimStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].trimEndFrame = trimEndFrame
        timeline.tracks[ti].clips[loc.clipIndex].startFrame += deltaStart
        timeline.tracks[ti].clips[loc.clipIndex].durationFrames = prevDuration - deltaStart - (trimEndFrame - prevEnd)

        let newEnd = timeline.tracks[ti].clips[loc.clipIndex].startFrame + timeline.tracks[ti].clips[loc.clipIndex].durationFrames
        let rippleDelta = newEnd - oldEnd
        if rippleDelta != 0 {
            let chainIds = timeline.tracks[ti].contiguousClipIds(fromEnd: oldEnd, excludeId: clipId)
            for ci in timeline.tracks[ti].clips.indices where chainIds.contains(timeline.tracks[ti].clips[ci].id) {
                timeline.tracks[ti].clips[ci].startFrame += rippleDelta
            }
        }
        sortClips(trackIndex: ti)

        undoManager?.registerUndo(withTarget: self) { $0.trimClip(clipId: clipId, trimStartFrame: prevStart, trimEndFrame: prevEnd) }
        undoManager?.setActionName("Trim Clip")
        notifyTimelineChanged()
    }

    func splitClip(clipId: String, atFrame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard atFrame > clip.startFrame && atFrame < clip.endFrame else { return }

        let splitOffset = atFrame - clip.startFrame
        var left = clip
        left.durationFrames = splitOffset
        left.trimEndFrame = clip.trimEndFrame + (clip.durationFrames - splitOffset)

        var right = clip
        right.id = UUID().uuidString
        right.startFrame = atFrame
        right.durationFrames = clip.durationFrames - splitOffset
        right.trimStartFrame = clip.trimStartFrame + splitOffset

        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = left
        timeline.tracks[loc.trackIndex].clips.append(right)
        sortClips(trackIndex: loc.trackIndex)

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.removeClipInternal(id: right.id)
            if let newLoc = vm.findClip(id: left.id) {
                vm.timeline.tracks[newLoc.trackIndex].clips[newLoc.clipIndex] = clip
            }
        }
        undoManager?.setActionName("Split Clip")
        notifyTimelineChanged()
    }

    func removeClips(ids: Set<String>) {
        var removed: [(clip: Clip, trackIndex: Int)] = []
        for i in timeline.tracks.indices {
            let matching = timeline.tracks[i].clips.filter { ids.contains($0.id) }
            for clip in matching { removed.append((clip, i)) }
            timeline.tracks[i].clips.removeAll { ids.contains($0.id) }
        }
        guard !removed.isEmpty else { return }
        selectedClipIds.subtract(ids)
        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { vm in
            for entry in removed {
                if vm.timeline.tracks.indices.contains(entry.trackIndex) {
                    vm.timeline.tracks[entry.trackIndex].clips.append(entry.clip)
                    vm.sortClips(trackIndex: entry.trackIndex)
                }
            }
        }
        pruneEmptyTracks()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Remove Clip\(removed.count == 1 ? "" : "s")")
        notifyTimelineChanged()
    }

    func updateClipProperty(clipId: String, _ modify: (inout Clip) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        modify(&timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        undoManager?.registerUndo(withTarget: self) { vm in
            if let current = vm.findClip(id: clipId) {
                vm.timeline.tracks[current.trackIndex].clips[current.clipIndex] = before
            }
        }
        undoManager?.setActionName("Change Clip Property")
        notifyTimelineChanged()
    }

    // MARK: - Playhead-relative operations (called from toolbar/shortcuts)

    func splitAtPlayhead() {
        for id in selectedClipIds {
            splitClip(clipId: id, atFrame: currentFrame)
        }
    }

    func trimStartToPlayhead() {
        for id in selectedClipIds {
            guard let loc = findClip(id: id) else { continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard currentFrame > clip.startFrame && currentFrame < clip.endFrame else { continue }
            let delta = currentFrame - clip.startFrame
            trimClip(clipId: id, trimStartFrame: clip.trimStartFrame + delta, trimEndFrame: clip.trimEndFrame)
        }
    }

    func trimEndToPlayhead() {
        for id in selectedClipIds {
            guard let loc = findClip(id: id) else { continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard currentFrame > clip.startFrame && currentFrame < clip.endFrame else { continue }
            let delta = clip.endFrame - currentFrame
            trimClip(clipId: id, trimStartFrame: clip.trimStartFrame, trimEndFrame: clip.trimEndFrame + delta)
        }
    }

    func deleteSelectedClips() {
        removeClips(ids: selectedClipIds)
    }

    func deleteSelectedMediaAssets() {
        let ids = selectedMediaAssetIds
        guard !ids.isEmpty else { return }
        mediaAssets.removeAll { ids.contains($0.id) }
        mediaManifest.entries.removeAll { ids.contains($0.id) }
        for id in ids { closePreviewTab(id: id) }
        selectedMediaAssetIds.removeAll()
    }

    /// Ripple delete: remove clips and shift subsequent clips backward to close gaps.
    func rippleDeleteSelectedClips() {
        let ids = selectedClipIds
        guard !ids.isEmpty else { return }

        undoManager?.beginUndoGrouping()

        // Compute shifts before removing
        var allShifts: [(trackIndex: Int, clipId: String, newStartFrame: Int)] = []
        for ti in timeline.tracks.indices {
            let shifts = RippleEngine.computeRippleShifts(
                clips: timeline.tracks[ti].clips,
                removedIds: ids
            )
            for s in shifts {
                allShifts.append((ti, s.clipId, s.newStartFrame))
            }
        }

        removeClips(ids: ids)

        for shift in allShifts {
            if let loc = findClip(id: shift.clipId) {
                let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = shift.newStartFrame
                undoManager?.registerUndo(withTarget: self) { vm in
                    if let current = vm.findClip(id: shift.clipId) {
                        vm.timeline.tracks[current.trackIndex].clips[current.clipIndex].startFrame = before
                    }
                }
            }
        }

        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Ripple Delete")
    }

    /// Clear a region on a track by removing, trimming, or splitting clips.
    func clearRegion(trackIndex: Int, start: Int, end: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let actions = OverwriteEngine.computeOverwrite(
            clips: timeline.tracks[trackIndex].clips,
            regionStart: start,
            regionEnd: end
        )

        for action in actions {
            switch action {
            case .remove(let clipId):
                removeClips(ids: [clipId])

            case .trimEnd(let clipId, let newDuration):
                if let loc = findClip(id: clipId) {
                    let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                    let newTrimEnd = clip.sourceDurationFrames - clip.trimStartFrame - newDuration
                    trimClip(clipId: clipId, trimStartFrame: clip.trimStartFrame, trimEndFrame: newTrimEnd)
                }

            case .trimStart(let clipId, _, let newTrimStart, _):
                if let loc = findClip(id: clipId) {
                    let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                    trimClip(clipId: clipId, trimStartFrame: newTrimStart, trimEndFrame: clip.trimEndFrame)
                }

            case .split(let clipId, _, _, _, _, _):
                if let loc = findClip(id: clipId) {
                    splitClip(clipId: clipId, atFrame: start)
                    // The right half after split starts at `start`
                    // We need to trim it to start at `end`
                    // Find the right half
                    let rightClips = timeline.tracks[loc.trackIndex].clips.filter {
                        $0.startFrame == start && $0.id != clipId
                    }
                    if let rightClip = rightClips.first {
                        // Now split this right half at `end` if it extends past
                        if rightClip.endFrame > end {
                            splitClip(clipId: rightClip.id, atFrame: end)
                            // Remove the middle piece (from start to end)
                            removeClips(ids: [rightClip.id])
                        } else {
                            // The right piece is entirely within the region — remove it
                            removeClips(ids: [rightClip.id])
                        }
                    }
                }
            }
        }
    }

    func rippleInsertClips(assets: [MediaAsset], trackIndex: Int, atFrame: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        undoManager?.beginUndoGrouping()
        let totalPush = assets.reduce(0) { $0 + secondsToFrame(seconds: $1.duration, fps: timeline.fps) }
        let shifts = RippleEngine.computeRipplePush(
            clips: timeline.tracks[trackIndex].clips,
            insertFrame: atFrame,
            pushAmount: totalPush
        )
        for shift in shifts {
            if let loc = findClip(id: shift.clipId) {
                let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = shift.newStartFrame
                let clipId = shift.clipId
                undoManager?.registerUndo(withTarget: self) { vm in
                    if let current = vm.findClip(id: clipId) {
                        vm.timeline.tracks[current.trackIndex].clips[current.clipIndex].startFrame = before
                    }
                }
            }
        }
        let clipIds = createClips(from: assets, trackIndex: trackIndex, startFrame: atFrame)
        sortClips(trackIndex: trackIndex)
        undoManager?.registerUndo(withTarget: self) { $0.removeClips(ids: Set(clipIds)) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Ripple Insert Clips")
        notifyTimelineChanged()
    }

    func overwriteInsertClips(assets: [MediaAsset], trackIndex: Int, atFrame: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let totalDuration = assets.reduce(0) { $0 + secondsToFrame(seconds: $1.duration, fps: timeline.fps) }
        undoManager?.beginUndoGrouping()
        clearRegion(trackIndex: trackIndex, start: atFrame, end: atFrame + totalDuration)
        let clipIds = createClips(from: assets, trackIndex: trackIndex, startFrame: atFrame)
        sortClips(trackIndex: trackIndex)
        undoManager?.registerUndo(withTarget: self) { $0.removeClips(ids: Set(clipIds)) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Overwrite Insert Clips")
        notifyTimelineChanged()
    }

    // MARK: - Private helpers

    /// Create clips from assets sequentially starting at `startFrame`, appending to the given track.
    @discardableResult
    private func createClips(
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
            let clip = Clip(mediaRef: asset.id, mediaType: asset.type, startFrame: resolvedStart, durationFrames: durationFrames)
            timeline.tracks[trackIndex].clips.append(clip)
            clipIds.append(clip.id)
            cursor = resolvedStart + durationFrames
        }
        return clipIds
    }

    func findClip(id: String) -> (trackIndex: Int, clipIndex: Int)? {
        for ti in timeline.tracks.indices {
            if let ci = timeline.tracks[ti].clips.firstIndex(where: { $0.id == id }) {
                return (ti, ci)
            }
        }
        return nil
    }

    func sortClips(trackIndex: Int) {
        timeline.tracks[trackIndex].clips.sort { $0.startFrame < $1.startFrame }
    }

    /// Returns the nearest non-overlapping startFrame for a clip on a track.
    /// Snaps forward to the end of the overlapping clip.
    private func resolveOverlap(trackIndex: Int, clipId: String, startFrame: Int, duration: Int) -> Int {
        let others = timeline.tracks[trackIndex].clips.filter { $0.id != clipId }
        var frame = startFrame
        var changed = true
        while changed {
            changed = false
            for other in others {
                let overlapStart = max(frame, other.startFrame)
                let overlapEnd = min(frame + duration, other.endFrame)
                if overlapStart < overlapEnd {
                    // Overlap detected — snap to end of blocking clip
                    frame = other.endFrame
                    changed = true
                }
            }
        }
        return frame
    }

    private func removeClipInternal(id: String) {
        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { $0.id == id }
        }
    }

    private func pruneEmptyTracks() {
        timeline.tracks.filter(\.clips.isEmpty).forEach { removeTrack(id: $0.id) }
    }
}
