import AppKit

/// Clip-level mutations: move, split, remove, speed, property edits, overwrite-style
/// region clearing, and the playhead-relative shortcuts that wrap them.
extension EditorViewModel {

    // MARK: - Add / move

    /// Move a clip to a newly-created track inserted at `insertAt`.
    func moveClipToNewTrack(clipId: String, insertAt: Int, clipType: ClipType, toFrame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        undoManager?.beginUndoGrouping()
        let newIndex = insertTrack(at: insertAt, type: clipType, label: clipType.trackLabel)
        // If we inserted before/at the clip's current track, its index shifted by 1
        let adjustedOriginal = newIndex <= loc.trackIndex ? loc.trackIndex + 1 : loc.trackIndex
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

    func moveClip(clipId: String, toTrack: Int, toFrame: Int) {
        guard let loc = findClip(id: clipId),
              timeline.tracks.indices.contains(toTrack) else { return }
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

    /// Batch-move clips in one undo group. Clamps the group delta so no moved clip
    /// overlaps a non-moved clip on the same destination track.
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

    // MARK: - Split / remove

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

    // MARK: - Speed

    func applyClipSpeed(clipId: String, newSpeed: Double) {
        guard let loc = findClip(id: clipId) else { return }
        if dragBefore == nil || dragBefore?.clipId != clipId {
            dragBefore = (clipId, timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        }
        setClipSpeed(at: loc, newSpeed: newSpeed)
    }

    func commitClipSpeed(clipId: String, newSpeed: Double) {
        guard let loc = findClip(id: clipId) else { return }
        let before = dragBefore?.clipId == clipId ? dragBefore?.clip : timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        dragBefore = nil
        setClipSpeed(at: loc, newSpeed: newSpeed)
        guard let before, before.speed != newSpeed else { return }
        undoManager?.registerUndo(withTarget: self) { vm in
            if let current = vm.findClip(id: clipId) {
                vm.setClipSpeed(at: current, newSpeed: before.speed)
                vm.undoManager?.registerUndo(withTarget: vm) { vm2 in
                    if let loc2 = vm2.findClip(id: clipId) {
                        vm2.setClipSpeed(at: loc2, newSpeed: newSpeed)
                    }
                }
                vm.undoManager?.setActionName("Change Speed")
            }
        }
        undoManager?.setActionName("Change Speed")
    }

    fileprivate func setClipSpeed(at loc: ClipLocation, newSpeed: Double) {
        let ti = loc.trackIndex
        let clip = timeline.tracks[ti].clips[loc.clipIndex]
        let sourceFrames = Double(clip.durationFrames) * clip.speed
        let newDuration = max(1, Int((sourceFrames / newSpeed).rounded()))
        let oldEnd = clip.endFrame

        timeline.tracks[ti].clips[loc.clipIndex].speed = newSpeed
        timeline.tracks[ti].clips[loc.clipIndex].durationFrames = newDuration

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

    func applyClipProperty(clipId: String, _ modify: (inout Clip) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        if dragBefore == nil || dragBefore?.clipId != clipId {
            dragBefore = (clipId, timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        }
        modify(&timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        videoEngine?.refreshVisuals()
    }

    func commitClipProperty(clipId: String, _ modify: (inout Clip) -> Void) {
        guard let loc = findClip(id: clipId) else { return }
        let before = dragBefore?.clipId == clipId ? dragBefore?.clip : timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        dragBefore = nil
        modify(&timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        if let before {
            undoManager?.registerUndo(withTarget: self) { vm in
                if let current = vm.findClip(id: clipId) {
                    vm.timeline.tracks[current.trackIndex].clips[current.clipIndex] = before
                }
            }
            undoManager?.setActionName("Change Clip Property")
        }
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
        var clipIdsToRemove: Set<String> = []
        for track in timeline.tracks {
            for clip in track.clips where ids.contains(clip.mediaRef) {
                clipIdsToRemove.insert(clip.id)
            }
        }
        if !clipIdsToRemove.isEmpty {
            removeClips(ids: clipIdsToRemove)
        }
        mediaAssets.removeAll { ids.contains($0.id) }
        mediaManifest.entries.removeAll { ids.contains($0.id) }
        for id in ids { closePreviewTab(id: id) }
        selectedMediaAssetIds.removeAll()
    }

    // MARK: - Overwrite region

    /// Clear a region on a track by removing, trimming, or splitting the clips that overlap it.
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
                    let rightClips = timeline.tracks[loc.trackIndex].clips.filter {
                        $0.startFrame == start && $0.id != clipId
                    }
                    if let rightClip = rightClips.first {
                        if rightClip.endFrame > end {
                            splitClip(clipId: rightClip.id, atFrame: end)
                            removeClips(ids: [rightClip.id])
                        } else {
                            removeClips(ids: [rightClip.id])
                        }
                    }
                }
            }
        }
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
}
