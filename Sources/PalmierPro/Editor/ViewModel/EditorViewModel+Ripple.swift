import AppKit

/// Ripple editing: trim, delete, insert, and the sync-lock machinery that keeps
/// other tracks aligned with the edit. See `RippleEngine` for the pure math.
extension EditorViewModel {

    // MARK: - Public API

    /// Trim one or more clips in a single undo group. Overwrite-style: each clip
    /// resizes in place — no adjacent-clip shift on the same track, no sync-lock
    /// push to other tracks.
    func trimClips(_ edits: [(clipId: String, trimStartFrame: Int, trimEndFrame: Int)]) {
        guard !edits.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        for e in edits {
            trimClipInternal(clipId: e.clipId, trimStartFrame: e.trimStartFrame, trimEndFrame: e.trimEndFrame)
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

    fileprivate func trimClipInternal(clipId: String, trimStartFrame: Int, trimEndFrame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        let ti = loc.trackIndex
        let clip = timeline.tracks[ti].clips[loc.clipIndex]
        let prevStart = clip.trimStartFrame
        let prevEnd = clip.trimEndFrame
        let prevDuration = clip.durationFrames
        // The incoming trim values are source frames; translate their deltas
        // into timeline frames before applying to `startFrame` / `durationFrames`.
        let deltaStartSource = trimStartFrame - prevStart
        let deltaEndSource = trimEndFrame - prevEnd
        let deltaStartTimeline = Int((Double(deltaStartSource) / clip.speed).rounded())
        let deltaEndTimeline = Int((Double(deltaEndSource) / clip.speed).rounded())
        let newDuration = prevDuration - deltaStartTimeline - deltaEndTimeline
        let newStartFrame = clip.startFrame + deltaStartTimeline

        undoManager?.beginUndoGrouping()

        timeline.tracks[ti].clips[loc.clipIndex].trimStartFrame = trimStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].trimEndFrame = trimEndFrame
        timeline.tracks[ti].clips[loc.clipIndex].startFrame = newStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].durationFrames = newDuration

        sortClips(trackIndex: ti)

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.trimClipInternal(clipId: clipId, trimStartFrame: prevStart, trimEndFrame: prevEnd)
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

    /// Refuse a ripple edit: beep + log.
    fileprivate func refuseRipple(reason: String) {
        NSSound.beep()
        Log.editor.notice("ripple blocked: \(reason)")
    }
}
