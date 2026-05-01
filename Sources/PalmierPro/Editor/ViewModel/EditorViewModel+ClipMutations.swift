import AppKit

/// Clip-level mutations: move, split, remove, speed, property edits, overwrite-style
/// region clearing, and the playhead-relative shortcuts that wrap them.
extension EditorViewModel {

    // MARK: - Add / move

    func addClips(assets: [MediaAsset], trackIndex: Int, startFrame: Int, linkedAudioTrackIndex: Int? = nil) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        // Pin by id: clearRegion's pruneEmptyTracks can shift indices.
        let visualTrackId = timeline.tracks[trackIndex].id
        let audioTrackId: String? = linkedAudioTrackIndex.flatMap {
            timeline.tracks.indices.contains($0) ? timeline.tracks[$0].id : nil
        }

        withTimelineSwap(actionName: "Add Clips") {
            let totalDur = assets.reduce(0) { $0 + secondsToFrame(seconds: $1.duration, fps: timeline.fps) }
            clearRegion(trackIndex: trackIndex, start: startFrame, end: startFrame + totalDur, prune: false)
            if let aid = audioTrackId,
               let audioIdx = timeline.tracks.firstIndex(where: { $0.id == aid }) {
                clearRegion(trackIndex: audioIdx, start: startFrame, end: startFrame + totalDur, prune: false)
            }

            guard let resolvedTrackIndex = timeline.tracks.firstIndex(where: { $0.id == visualTrackId }) else {
                pruneEmptyTracks()
                return
            }
            let resolvedAudioIndex: Int? = audioTrackId.flatMap { id in
                timeline.tracks.firstIndex(where: { $0.id == id })
            }

            createClips(
                from: assets, trackIndex: resolvedTrackIndex, startFrame: startFrame,
                linkedAudioTrackIndex: resolvedAudioIndex
            )
            sortClips(trackIndex: resolvedTrackIndex)
            pruneEmptyTracks()
        }
    }

    /// Moved clips share a single delta from the drag, so they don't collide with each other.
    func moveClips(_ moves: [(clipId: String, toTrack: Int, toFrame: Int)]) {
        guard !moves.isEmpty else { return }

        // Collect current state + validate track-type compatibility.
        var clipInfos: [(clip: Clip, fromTrack: Int, toTrack: Int, toFrame: Int)] = []
        for m in moves {
            guard let loc = findClip(id: m.clipId),
                  timeline.tracks.indices.contains(m.toTrack) else { continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            let destType = timeline.tracks[m.toTrack].type
            let srcType = timeline.tracks[loc.trackIndex].type
            guard destType.isCompatible(with: srcType) else { continue }
            clipInfos.append((clip, loc.trackIndex, m.toTrack, max(0, m.toFrame)))
        }
        guard !clipInfos.isEmpty else { return }

        let actionName = moves.count == 1 ? "Move Clip" : "Move Clips"
        withTimelineSwap(actionName: actionName) {
            // Pull moved clips off their source tracks first, so clearRegion on
            // the destinations never touches them.
            for info in clipInfos {
                if let loc = findClip(id: info.clip.id) {
                    timeline.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
                }
            }

            // Trim / remove any non-moved clips blocking each destination range.
            // Pin by id: clearRegion's pruneEmptyTracks can shift indices.
            let toTrackIds = clipInfos.map { timeline.tracks[$0.toTrack].id }
            for (i, info) in clipInfos.enumerated() {
                guard let idx = timeline.tracks.firstIndex(where: { $0.id == toTrackIds[i] }) else { continue }
                clearRegion(trackIndex: idx, start: info.toFrame, end: info.toFrame + info.clip.durationFrames, prune: false)
            }

            // Drop each clip at its exact target frame.
            for (i, info) in clipInfos.enumerated() {
                guard let idx = timeline.tracks.firstIndex(where: { $0.id == toTrackIds[i] }) else { continue }
                var clip = info.clip
                clip.startFrame = info.toFrame
                timeline.tracks[idx].clips.append(clip)
            }
            for i in timeline.tracks.indices { sortClips(trackIndex: i) }
            pruneEmptyTracks()
        }
    }

    // MARK: - Split / remove

    /// Split `clipId` at `atFrame`. Also splits linked partners.
    /// Returns the IDs of the right-half clips created by the split.
    @discardableResult
    func splitClip(clipId: String, atFrame: Int) -> [String] {
        guard let loc = findClip(id: clipId) else { return [] }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let groupIds: Set<String> = clip.linkGroupId != nil
            ? Set([clipId] + linkedPartnerIds(of: clipId))
            : [clipId]

        undoManager?.beginUndoGrouping()
        var rightIds: [String] = []
        for id in groupIds {
            if let rightId = splitSingleClip(clipId: id, atFrame: atFrame) {
                rightIds.append(rightId)
            }
        }
        // Regroup the right halves so each side is its own linked pair.
        if groupIds.count > 1 && !rightIds.isEmpty {
            let newGroup = UUID().uuidString
            mutateClips(ids: Set(rightIds), actionName: "Split Clip") { $0.linkGroupId = newGroup }
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(groupIds.count > 1 ? "Split Clips" : "Split Clip")
        return rightIds
    }

    @discardableResult
    private func splitSingleClip(clipId: String, atFrame: Int) -> String? {
        guard let loc = findClip(id: clipId) else { return nil }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard atFrame > clip.startFrame && atFrame < clip.endFrame else { return nil }

        let splitOffset = atFrame - clip.startFrame
        let leftSource = Int((Double(splitOffset) * clip.speed).rounded())
        let rightSource = Int((Double(clip.durationFrames - splitOffset) * clip.speed).rounded())

        var left = clip
        left.durationFrames = splitOffset
        left.trimEndFrame = clip.trimEndFrame + rightSource
        left.audioFadeOutFrames = 0
        left.audioFadeInFrames = left.clampedFade(left.audioFadeInFrames, edge: .left)

        var right = clip
        right.id = UUID().uuidString
        right.startFrame = atFrame
        right.durationFrames = clip.durationFrames - splitOffset
        right.trimStartFrame = clip.trimStartFrame + leftSource
        right.audioFadeInFrames = 0
        right.audioFadeOutFrames = right.clampedFade(right.audioFadeOutFrames, edge: .right)

        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = left
        timeline.tracks[loc.trackIndex].clips.append(right)
        sortClips(trackIndex: loc.trackIndex)

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.removeClipInternal(id: right.id)
            if let newLoc = vm.findClip(id: left.id) {
                vm.timeline.tracks[newLoc.trackIndex].clips[newLoc.clipIndex] = clip
            }
        }
        notifyTimelineChanged()
        return right.id
    }

    func removeClips(ids: Set<String>, prune: Bool = true) {
        let hasMatches = timeline.tracks.contains { t in t.clips.contains { ids.contains($0.id) } }
        guard hasMatches else { return }
        let count = timeline.tracks.reduce(0) { $0 + $1.clips.lazy.filter { ids.contains($0.id) }.count }
        selectedClipIds.subtract(ids)
        withTimelineSwap(actionName: "Remove Clip\(count == 1 ? "" : "s")") {
            for i in timeline.tracks.indices {
                timeline.tracks[i].clips.removeAll { ids.contains($0.id) }
            }
            if prune { pruneEmptyTracks() }
        }
    }

    // MARK: - Speed

    func applyClipSpeed(clipId: String, newSpeed: Double) {
        guard let loc = findClip(id: clipId) else { return }
        if preDragTimeline == nil {
            preDragTimeline = timeline
        }
        if dragBefore[clipId] == nil {
            dragBefore[clipId] = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        }
        setClipSpeed(at: loc, newSpeed: newSpeed)
    }

    func commitClipSpeed(ids: [String], newSpeed: Double) {
        let before: Timeline = preDragTimeline ?? timeline
        for id in ids {
            guard let loc = findClip(id: id) else { continue }
            if timeline.tracks[loc.trackIndex].clips[loc.clipIndex].speed != newSpeed {
                setClipSpeed(at: loc, newSpeed: newSpeed)
            }
        }
        let after = timeline
        preDragTimeline = nil
        for id in ids { dragBefore.removeValue(forKey: id) }
        guard before != after else { return }
        registerTimelineSwap(undoState: before, redoState: after, actionName: "Change Speed")
    }

    func registerTimelineSwap(undoState: Timeline, redoState: Timeline, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.timeline = undoState
            vm.notifyTimelineChanged()
            vm.registerTimelineSwap(undoState: redoState, redoState: undoState, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Run `work` as a single atomic mutation, registering one timeline-swap undo
    func withTimelineSwap(actionName: String, _ work: () -> Void) {
        let before = timeline
        undoManager?.disableUndoRegistration()
        work()
        undoManager?.enableUndoRegistration()
        let after = timeline
        guard before != after else { return }
        // Skip when nested: an outer withTimelineSwap is still suppressing
        // registrations and will capture our diff in its own swap.
        guard undoManager?.isUndoRegistrationEnabled ?? true else { return }
        registerTimelineSwap(undoState: before, redoState: after, actionName: actionName)
        notifyTimelineChanged()
    }

    fileprivate func setClipSpeed(at loc: ClipLocation, newSpeed: Double) {
        let ti = loc.trackIndex
        let clip = timeline.tracks[ti].clips[loc.clipIndex]
        let basis = dragBefore[clip.id] ?? clip
        let sourceFrames = Double(basis.durationFrames) * basis.speed
        let newDuration = max(1, Int((sourceFrames / newSpeed).rounded()))
        let oldEnd = clip.endFrame

        timeline.tracks[ti].clips[loc.clipIndex].speed = newSpeed
        timeline.tracks[ti].clips[loc.clipIndex].durationFrames = newDuration
        timeline.tracks[ti].clips[loc.clipIndex].clampFadesToDuration()

        let rippleDelta = (clip.startFrame + newDuration) - oldEnd
        if rippleDelta != 0 {
            let chainIds = timeline.tracks[ti].contiguousClipIds(fromEnd: oldEnd, excludeId: clip.id)
            for ci in timeline.tracks[ti].clips.indices where chainIds.contains(timeline.tracks[ti].clips[ci].id) {
                timeline.tracks[ti].clips[ci].startFrame += rippleDelta
            }
        }
        sortClips(trackIndex: ti)
        notifyTimelineChanged()
    }

    // MARK: - Generic property edits

    // MARK: - Multi-clip atomic mutation

    /// Apply `modify` to every clip whose id is in `ids`. Captures a full-clip
    /// before snapshot for each and registers a bidirectional undo/redo swap
    func mutateClips(ids: Set<String>, actionName: String, _ modify: (inout Clip) -> Void) {
        var before: [(id: String, clip: Clip)] = []
        for ti in timeline.tracks.indices {
            for ci in timeline.tracks[ti].clips.indices where ids.contains(timeline.tracks[ti].clips[ci].id) {
                before.append((timeline.tracks[ti].clips[ci].id, timeline.tracks[ti].clips[ci]))
                modify(&timeline.tracks[ti].clips[ci])
            }
        }
        guard !before.isEmpty else { return }
        let after: [(id: String, clip: Clip)] = before.compactMap { entry in
            guard let loc = findClip(id: entry.id) else { return nil }
            return (entry.id, timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        }
        registerClipStateSwap(undoTarget: before, redoTarget: after, actionName: actionName)
        notifyTimelineChanged()
    }

    /// Register an undo that rewrites the clips to `undoTarget`, then re-registers
    /// the inverse swap so redo reapplies `redoTarget`.
    fileprivate func registerClipStateSwap(
        undoTarget: [(id: String, clip: Clip)],
        redoTarget: [(id: String, clip: Clip)],
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { vm in
            for entry in undoTarget {
                if let loc = vm.findClip(id: entry.id) {
                    vm.timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = entry.clip
                }
            }
            vm.registerClipStateSwap(undoTarget: redoTarget, redoTarget: undoTarget, actionName: actionName)
            vm.notifyTimelineChanged()
        }
        undoManager?.setActionName(actionName)
    }

    func applyClipProperty(clipId: String, rebuild: Bool = false, _ modify: (inout Clip) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        var clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        if dragBefore[clipId] == nil {
            dragBefore[clipId] = clip
        }
        modify(&clip)
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
        // Text renders via CATextLayer overlay — skip the composition path.
        if clip.mediaType == .text {
            videoEngine?.syncTextLayers()
            return
        }
        if rebuild {
            notifyTimelineChangedDebounced()
        } else {
            videoEngine?.refreshVisuals()
        }
    }

    func revertClipProperty(clipId: String) {
        guard let original = dragBefore.removeValue(forKey: clipId),
              let loc = findClip(id: clipId) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = original
        if original.mediaType == .text {
            videoEngine?.syncTextLayers()
        } else {
            notifyTimelineChanged()
        }
    }

    /// Apply live, commit one undo entry after `debounce` of quiet —
    /// for continuous controls without drag-end events (ColorPicker).
    func debouncedCommitClipProperty(
        clipId: String,
        key: String,
        debounce: Duration = .milliseconds(400),
        _ modify: @escaping (inout Clip) -> Void
    ) {
        applyClipProperty(clipId: clipId, rebuild: true, modify)
        let taskKey = "\(clipId):\(key)"
        pendingDebouncedCommits[taskKey]?.cancel()
        pendingDebouncedCommits[taskKey] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.commitClipProperty(clipId: clipId, modify)
            self.pendingDebouncedCommits.removeValue(forKey: taskKey)
        }
    }

    // MARK: - Text-style mutation helpers

    func applyTextStyle(clipId: String, _ modify: @escaping (inout TextStyle) -> Void) {
        applyClipProperty(clipId: clipId, rebuild: true) { clip in
            var style = clip.textStyle ?? TextStyle()
            modify(&style)
            clip.textStyle = style
        }
    }

    func commitTextStyle(clipId: String, _ modify: @escaping (inout TextStyle) -> Void) {
        commitClipProperty(clipId: clipId) { clip in
            var style = clip.textStyle ?? TextStyle()
            modify(&style)
            clip.textStyle = style
        }
    }

    func debouncedCommitTextStyle(
        clipId: String,
        key: String,
        _ modify: @escaping (inout TextStyle) -> Void
    ) {
        debouncedCommitClipProperty(clipId: clipId, key: key) { clip in
            var style = clip.textStyle ?? TextStyle()
            modify(&style)
            clip.textStyle = style
        }
    }

    func commitClipProperty(clipId: String, _ modify: (inout Clip) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        var clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let before = dragBefore.removeValue(forKey: clipId) ?? clip
        modify(&clip)
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
        registerClipPropertySwap(clipId: clipId, undoTarget: before, redoTarget: clip)
        if clip.mediaType == .text {
            videoEngine?.syncTextLayers()
        } else {
            notifyTimelineChanged()
        }
    }

    /// Bidirectional undo/redo for a single clip's property change.
    fileprivate func registerClipPropertySwap(clipId: String, undoTarget: Clip, redoTarget: Clip) {
        undoManager?.registerUndo(withTarget: self) { vm in
            if let loc = vm.findClip(id: clipId) {
                vm.timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = undoTarget
            }
            vm.registerClipPropertySwap(clipId: clipId, undoTarget: redoTarget, redoTarget: undoTarget)
            if undoTarget.mediaType == .text {
                vm.videoEngine?.syncTextLayers()
            } else {
                vm.notifyTimelineChanged()
            }
        }
        undoManager?.setActionName("Change Clip Property")
    }

    /// Flag the selected clip (and any linked clips sharing its `mediaRef`)
    /// as awaiting an AI-generated replacement.
    func markPendingReplacement(clipId: String) {
        let ids = linkedClipIdsSharingMedia(anchor: clipId)
        pendingReplacements.formUnion(ids)
    }

    /// Clear the pending-replacement flag on the selected clip and any linked
    /// clips that were marked together.
    func clearPendingReplacement(clipId: String) {
        let ids = linkedClipIdsSharingMedia(anchor: clipId)
        pendingReplacements.subtract(ids)
        pendingReplacements.remove(clipId)
    }

    private func linkedClipIdsSharingMedia(anchor: String) -> Set<String> {
        guard let loc = findClip(id: anchor) else { return [anchor] }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        var ids: Set<String> = [anchor]
        if let groupId = clip.linkGroupId {
            let mediaRef = clip.mediaRef
            for track in timeline.tracks {
                for c in track.clips where c.linkGroupId == groupId && c.mediaRef == mediaRef {
                    ids.insert(c.id)
                }
            }
        }
        return ids
    }

    /// Replace the source asset a clip points at, preserving states. 
    /// Registered as a single undo step.
    func replaceClipMediaRef(clipId: String, newAssetId: String, resetTrim: Bool = false) {
        guard let loc = findClip(id: clipId) else { return }
        let oldMediaRef = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaRef
        guard oldMediaRef != newAssetId else { return }

        let targetIds = linkedClipIdsSharingMedia(anchor: clipId)

        var oldTrims: [String: (start: Int, end: Int)] = [:]
        for id in targetIds {
            if let l = findClip(id: id) {
                if resetTrim {
                    let c = timeline.tracks[l.trackIndex].clips[l.clipIndex]
                    oldTrims[id] = (c.trimStartFrame, c.trimEndFrame)
                    timeline.tracks[l.trackIndex].clips[l.clipIndex].trimStartFrame = 0
                    timeline.tracks[l.trackIndex].clips[l.clipIndex].trimEndFrame = 0
                }
                timeline.tracks[l.trackIndex].clips[l.clipIndex].mediaRef = newAssetId
            }
        }

        undoManager?.registerUndo(withTarget: self) { vm in
            for id in targetIds {
                if let l = vm.findClip(id: id) {
                    vm.timeline.tracks[l.trackIndex].clips[l.clipIndex].mediaRef = oldMediaRef
                    if let old = oldTrims[id] {
                        vm.timeline.tracks[l.trackIndex].clips[l.clipIndex].trimStartFrame = old.start
                        vm.timeline.tracks[l.trackIndex].clips[l.clipIndex].trimEndFrame = old.end
                    }
                }
            }
            vm.notifyTimelineChanged()
        }
        undoManager?.setActionName("Replace Clip Source")
        notifyTimelineChanged()
    }

    // MARK: - Playhead-relative operations

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
            let sourceDelta = Int((Double(delta) * clip.speed).rounded())
            trimClips([(clipId: id, trimStartFrame: clip.trimStartFrame + sourceDelta, trimEndFrame: clip.trimEndFrame)])
        }
    }

    func trimEndToPlayhead() {
        for id in selectedClipIds {
            guard let loc = findClip(id: id) else { continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard currentFrame > clip.startFrame && currentFrame < clip.endFrame else { continue }
            let delta = clip.endFrame - currentFrame
            let sourceDelta = Int((Double(delta) * clip.speed).rounded())
            trimClips([(clipId: id, trimStartFrame: clip.trimStartFrame, trimEndFrame: clip.trimEndFrame + sourceDelta)])
        }
    }

    func deleteSelectedClips() {
        removeClips(ids: selectedClipIds)
    }

    func deleteSelectedMediaAssets() {
        let ids = selectedMediaAssetIds
        guard !ids.isEmpty else { return }

        let clipIdsToRemove = Set(timeline.tracks
            .flatMap(\.clips)
            .filter { ids.contains($0.mediaRef) }
            .map(\.id))
        if !clipIdsToRemove.isEmpty {
            removeClips(ids: clipIdsToRemove)
        }

        let deletedSet = ids.intersection(Set(mediaAssets.map(\.id)))
        let promotions = planStackPromotions(forDeletedIds: deletedSet)

        mediaAssets.removeAll { ids.contains($0.id) }
        mediaManifest.entries.removeAll { ids.contains($0.id) }
        applyStackPromotions(promotions)

        for id in ids { closePreviewTab(id: id) }
        selectedMediaAssetIds.removeAll()
    }

    // MARK: - Overwrite region

    /// Clear a region on a track by removing, trimming, or splitting the clips that overlap it.
    func clearRegion(trackIndex: Int, start: Int, end: Int, prune: Bool = true) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let actions = OverwriteEngine.computeOverwrite(
            clips: timeline.tracks[trackIndex].clips,
            regionStart: start,
            regionEnd: end
        )

        for action in actions {
            switch action {
            case .remove(let clipId):
                removeClips(ids: [clipId], prune: prune)

            case .trimEnd(let clipId, let newDuration):
                if let loc = findClip(id: clipId) {
                    let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                    let sourceDelta = Int((Double(clip.durationFrames - newDuration) * clip.speed).rounded())
                    let newTrimEnd = clip.trimEndFrame + sourceDelta
                    mutateClips(ids: [clipId], actionName: "Trim Clip") {
                        $0.trimEndFrame = newTrimEnd
                        $0.durationFrames = newDuration
                        $0.clampFadesToDuration()
                    }
                }

            case .trimStart(let clipId, let newStartFrame, let newTrimStart, let newDuration):
                mutateClips(ids: [clipId], actionName: "Trim Clip") {
                    $0.startFrame = newStartFrame
                    $0.trimStartFrame = newTrimStart
                    $0.durationFrames = newDuration
                    $0.clampFadesToDuration()
                }

            case .split(let clipId, _, _, _, _, _):
                if let loc = findClip(id: clipId) {
                    splitClip(clipId: clipId, atFrame: start)
                    let rightClips = timeline.tracks[loc.trackIndex].clips.filter {
                        $0.startFrame == start && $0.id != clipId
                    }
                    if let rightClip = rightClips.first {
                        if rightClip.endFrame > end {
                            splitClip(clipId: rightClip.id, atFrame: end)
                            removeClips(ids: [rightClip.id], prune: prune)
                        } else {
                            removeClips(ids: [rightClip.id], prune: prune)
                        }
                    }
                }
            }
        }
    }

}
