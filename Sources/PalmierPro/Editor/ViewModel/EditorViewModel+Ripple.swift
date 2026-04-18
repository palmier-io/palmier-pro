import AppKit

/// Ripple editing: trim, delete, insert, and the sync-lock machinery that keeps
/// other tracks aligned with the edit. See `RippleEngine` for the pure math.
extension EditorViewModel {

    // MARK: - Public API

    /// Ripple-trim one or more clips in a single undo group. Adjacent clips on
    /// each edit's track shift to stay contiguous. A multi-edit call (linked
    /// partners trimmed together) skips cross-track sync-lock push so the
    /// caller's own per-partner trim doesn't double-shift other tracks.
    func trimClips(_ edits: [(clipId: String, trimStartFrame: Int, trimEndFrame: Int)]) {
        guard !edits.isEmpty else { return }
        let applySyncLock = edits.count == 1
        undoManager?.beginUndoGrouping()
        for e in edits {
            trimClipInternal(
                clipId: e.clipId,
                trimStartFrame: e.trimStartFrame,
                trimEndFrame: e.trimEndFrame,
                applySyncLock: applySyncLock
            )
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(edits.count == 1 ? "Trim Clip" : "Trim Clips")
    }

    /// Ripple delete: remove selected clips and close the gaps. Sync-locked tracks shift
    /// along to preserve cross-track alignment; refuses if any would collide.
    func rippleDeleteSelectedClips() {
        let ids = selectedClipIds
        guard !ids.isEmpty else { return }

        // Merged ranges used to shift sync-locked tracks that have no deletions of their own.
        let globalRemovedRanges: [FrameRange] = timeline.tracks
            .flatMap(\.clips)
            .filter { ids.contains($0.id) }
            .map { FrameRange(start: $0.startFrame, end: $0.endFrame) }

        var shiftsByTrack: [Int: [ClipShift]] = [:]
        for ti in timeline.tracks.indices {
            let track = timeline.tracks[ti]
            let hasOwnRemovals = track.clips.contains { ids.contains($0.id) }
            if hasOwnRemovals {
                shiftsByTrack[ti] = RippleEngine.computeRippleShifts(clips: track.clips, removedIds: ids)
            } else if track.syncLocked {
                shiftsByTrack[ti] = RippleEngine.computeRippleShiftsForRanges(
                    clips: track.clips,
                    removedRanges: globalRemovedRanges
                )
                if let reason = validateShifts(trackIndex: ti, shifts: shiftsByTrack[ti] ?? []) {
                    refuseRipple(reason: reason)
                    return
                }
            }
        }

        undoManager?.beginUndoGrouping()
        removeClips(ids: ids)
        shiftsByTrack.values.forEach { $0.forEach(applyShiftWithUndo) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Ripple Delete")
    }

    /// Ripple insert: add clips at `atFrame` and push everything past it right by the
    /// insertion's duration on the target track and every sync-locked track.
    func rippleInsertClips(assets: [MediaAsset], trackIndex: Int, atFrame: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        undoManager?.beginUndoGrouping()
        let totalPush = assets.reduce(0) { $0 + secondsToFrame(seconds: $1.duration, fps: timeline.fps) }

        for ti in timeline.tracks.indices where ti == trackIndex || timeline.tracks[ti].syncLocked {
            RippleEngine.computeRipplePush(
                clips: timeline.tracks[ti].clips,
                insertFrame: atFrame,
                pushAmount: totalPush
            ).forEach(applyShiftWithUndo)
        }
        let clipIds = createClips(from: assets, trackIndex: trackIndex, startFrame: atFrame)
        sortClips(trackIndex: trackIndex)
        undoManager?.registerUndo(withTarget: self) { $0.removeClips(ids: Set(clipIds)) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Ripple Insert Clips")
        notifyTimelineChanged()
    }

    // MARK: - Internal

    /// `applySyncLock=false` on the undo path: per-clip undos in `applySyncLockShift` already
    /// reverse the forward push; re-applying here would double-shift clips in the delta zone.
    fileprivate func trimClipInternal(clipId: String, trimStartFrame: Int, trimEndFrame: Int, applySyncLock: Bool) {
        guard let loc = findClip(id: clipId) else { return }
        let ti = loc.trackIndex
        let clip = timeline.tracks[ti].clips[loc.clipIndex]
        let prevStart = clip.trimStartFrame
        let prevEnd = clip.trimEndFrame
        let prevDuration = clip.durationFrames
        let oldEnd = clip.startFrame + clip.durationFrames
        let deltaStart = trimStartFrame - prevStart
        let newDuration = prevDuration - deltaStart - (trimEndFrame - prevEnd)
        let newStartFrame = clip.startFrame + deltaStart
        let rippleDelta = (newStartFrame + newDuration) - oldEnd

        if applySyncLock && rippleDelta != 0,
           let reason = firstSyncLockConflict(excludingTrack: ti, insertFrame: oldEnd, pushAmount: rippleDelta) {
            refuseRipple(reason: reason)
            return
        }

        undoManager?.beginUndoGrouping()

        timeline.tracks[ti].clips[loc.clipIndex].trimStartFrame = trimStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].trimEndFrame = trimEndFrame
        timeline.tracks[ti].clips[loc.clipIndex].startFrame = newStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].durationFrames = newDuration

        if rippleDelta != 0 {
            let chainIds = timeline.tracks[ti].contiguousClipIds(fromEnd: oldEnd, excludeId: clipId)
            for ci in timeline.tracks[ti].clips.indices where chainIds.contains(timeline.tracks[ti].clips[ci].id) {
                timeline.tracks[ti].clips[ci].startFrame += rippleDelta
            }
            if applySyncLock {
                applySyncLockShift(excludingTrack: ti, insertFrame: oldEnd, pushAmount: rippleDelta)
            }
        }
        sortClips(trackIndex: ti)

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.trimClipInternal(clipId: clipId, trimStartFrame: prevStart, trimEndFrame: prevEnd, applySyncLock: !applySyncLock)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Trim Clip")
        notifyTimelineChanged()
    }

    // MARK: - Shift plumbing

    /// Apply a shift and register an undo that restores the prior startFrame.
    fileprivate func applyShiftWithUndo(_ shift: ClipShift) {
        guard let loc = findClip(id: shift.clipId) else { return }
        let before = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = shift.newStartFrame
        let clipId = shift.clipId
        undoManager?.registerUndo(withTarget: self) { vm in
            if let l = vm.findClip(id: clipId) {
                vm.timeline.tracks[l.trackIndex].clips[l.clipIndex].startFrame = before
            }
        }
    }

    /// Push clips on every sync-locked track other than `excludingTrack`. Per-clip undos
    /// are required — the re-entrant trim undo can't recompute the inverse correctly.
    fileprivate func applySyncLockShift(excludingTrack: Int, insertFrame: Int, pushAmount: Int) {
        for ti in timeline.tracks.indices where ti != excludingTrack && timeline.tracks[ti].syncLocked {
            RippleEngine.computeRipplePush(
                clips: timeline.tracks[ti].clips,
                insertFrame: insertFrame,
                pushAmount: pushAmount
            ).forEach(applyShiftWithUndo)
            sortClips(trackIndex: ti)
        }
    }

    // MARK: - Validation

    /// Dry-run: returns a blocking reason (collision or negative startFrame) or nil if safe.
    fileprivate func validateShifts(trackIndex: Int, shifts: [ClipShift]) -> String? {
        guard !shifts.isEmpty, timeline.tracks.indices.contains(trackIndex) else { return nil }
        let track = timeline.tracks[trackIndex]
        let shiftMap = Dictionary(uniqueKeysWithValues: shifts.map { ($0.clipId, $0.newStartFrame) })
        var intervals: [FrameRange] = []
        for clip in track.clips {
            let start = shiftMap[clip.id] ?? clip.startFrame
            if start < 0 {
                return "Sync-locked track \"\(track.label)\" would move past the timeline start."
            }
            intervals.append(FrameRange(start: start, end: start + clip.durationFrames))
        }
        intervals.sort { $0.start < $1.start }
        for i in 1..<intervals.count where intervals[i].start < intervals[i-1].end {
            return "Sync-locked track \"\(track.label)\" doesn't have room to ripple."
        }
        return nil
    }

    /// Dry-run of `applySyncLockShift`; returns the first blocking reason or nil.
    fileprivate func firstSyncLockConflict(excludingTrack: Int, insertFrame: Int, pushAmount: Int) -> String? {
        for ti in timeline.tracks.indices where ti != excludingTrack && timeline.tracks[ti].syncLocked {
            let shifts = RippleEngine.computeRipplePush(
                clips: timeline.tracks[ti].clips,
                insertFrame: insertFrame,
                pushAmount: pushAmount
            )
            if let reason = validateShifts(trackIndex: ti, shifts: shifts) { return reason }
        }
        return nil
    }

    /// Refuse a ripple edit: beep + log.
    fileprivate func refuseRipple(reason: String) {
        NSSound.beep()
        NSLog("[palmier] ripple blocked: %@", reason)
    }
}
