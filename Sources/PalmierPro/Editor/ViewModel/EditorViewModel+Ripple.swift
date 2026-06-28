import AppKit

struct RippleRangesReport: Sendable {
    let removedFrames: Int
    let clearedTracks: Int
    let shiftedClips: Int
    let anchorTrackIndex: Int
    let resultingFragments: [(clipId: String, startFrame: Int, durationFrames: Int)]
    let removedClipIds: [String]
}

enum RippleRangesOutcome: Sendable {
    case ok(RippleRangesReport)
    case refused(String)
}

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

        withTimelineSwap(actionName: "Ripple Delete") {
            removeClips(ids: ids)
            for shifts in shiftsByTrack.values { applyShifts(shifts) }
        }
    }

    @discardableResult
    func applyShifts(_ shifts: [ClipShift]) -> Int {
        var applied = 0
        for shift in shifts {
            guard let loc = findClip(id: shift.clipId) else { continue }
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = shift.newStartFrame
            applied += 1
        }
        return applied
    }

    /// Ripple-delete timeline-frame `ranges` anchored to `anchorClipId`
    func rippleDeleteRanges(anchorClipId: String, ranges: [FrameRange]) -> RippleRangesOutcome {
        guard let anchorLoc = findClip(id: anchorClipId) else {
            return .refused("Clip not found: \(anchorClipId)")
        }
        return rippleDeleteRangesOnTrack(trackIndex: anchorLoc.trackIndex, ranges: ranges)
    }

    /// Deletes project-frame ranges from one track (spanning any clips) and closes the gaps; cuts linked A/V partners, shifts sync-locked tracks, refuses if any can't absorb.
    /// Tracks in `ignoreSyncLockTrackIndices` are treated as unlocked for this call only
    func rippleDeleteRangesOnTrack(trackIndex: Int, ranges: [FrameRange], ignoreSyncLockTrackIndices: Set<Int> = []) -> RippleRangesOutcome {
        guard timeline.tracks.indices.contains(trackIndex) else {
            return .refused("Track index out of range: \(trackIndex)")
        }
        let ignoredTrackIds = Set(ignoreSyncLockTrackIndices.compactMap {
            timeline.tracks.indices.contains($0) ? timeline.tracks[$0].id : nil
        })
        let merged = RippleEngine.mergeRanges(ranges.filter { $0.length > 0 })
        guard !merged.isEmpty else { return .refused("No non-empty ranges to delete") }
        let totalRemoved = merged.reduce(0) { $0 + $1.length }

        let anchorTrackId = timeline.tracks[trackIndex].id
        var clearTrackIds: Set<String> = [anchorTrackId]
        // Linked partners of every touched clip, so A/V stays in sync across multi-clip ranges.
        for clip in timeline.tracks[trackIndex].clips
        where clip.linkGroupId != nil && merged.contains(where: { $0.start < clip.endFrame && $0.end > clip.startFrame }) {
            for pid in linkedPartnerIds(of: clip.id) {
                if let l = findClip(id: pid) { clearTrackIds.insert(timeline.tracks[l.trackIndex].id) }
            }
        }

        // Refuse up front if a sync-locked follower can't absorb the shift. These tracks
        // aren't cleared, so their clips are unchanged when the shift is applied below.
        for ti in timeline.tracks.indices {
            let track = timeline.tracks[ti]
            guard !clearTrackIds.contains(track.id), track.syncLocked, !ignoredTrackIds.contains(track.id) else { continue }
            let shifts = RippleEngine.computeRippleShiftsForRanges(clips: track.clips, removedRanges: merged)
            if let reason = validateShifts(trackIndex: ti, shifts: shifts) {
                return .refused(reason)
            }
        }

        let anchorBeforeIds = Set(timeline.tracks[trackIndex].clips.map(\.id))

        var shiftedClips = 0
        withTimelineSwap(actionName: "Ripple Delete") {
            for tid in clearTrackIds {
                guard let ti = timeline.tracks.firstIndex(where: { $0.id == tid }) else { continue }
                for r in merged {
                    clearRegion(trackIndex: ti, start: r.start, end: r.end, prune: false)
                }
            }
            for ti in timeline.tracks.indices {
                let track = timeline.tracks[ti]
                guard clearTrackIds.contains(track.id) || (track.syncLocked && !ignoredTrackIds.contains(track.id)) else { continue }
                let shifts = RippleEngine.computeRippleShiftsForRanges(clips: track.clips, removedRanges: merged)
                shiftedClips += applyShifts(shifts)
                sortClips(trackIndex: ti)
            }
        }

        // Anchor track's post-cut layout (surviving + new fragments) so the caller needn't re-read.
        let anchorTi = timeline.tracks.firstIndex { $0.id == anchorTrackId } ?? trackIndex
        let afterClips = timeline.tracks[anchorTi].clips
        let afterIds = Set(afterClips.map(\.id))
        let fragments = afterClips
            .filter { afterIds.subtracting(anchorBeforeIds).contains($0.id) || anchorBeforeIds.contains($0.id) }
            .sorted { $0.startFrame < $1.startFrame }
            .map { (clipId: $0.id, startFrame: $0.startFrame, durationFrames: $0.durationFrames) }
        return .ok(RippleRangesReport(
            removedFrames: totalRemoved,
            clearedTracks: clearTrackIds.count,
            shiftedClips: shiftedClips,
            anchorTrackIndex: anchorTi,
            resultingFragments: fragments,
            removedClipIds: Array(anchorBeforeIds.subtracting(afterIds))
        ))
    }

    func rippleDeleteSelectedGap() {
        guard let gap = selectedGap,
              timeline.tracks.indices.contains(gap.trackIndex),
              gap.range.length > 0 else { return }
        // An out-of-band edit may have filled the gap.
        guard !timeline.tracks[gap.trackIndex].clips.contains(where: {
            $0.startFrame < gap.range.end && $0.endFrame > gap.range.start
        }) else { selectedGap = nil; return }

        var shiftsByTrack: [Int: [ClipShift]] = [:]
        for ti in timeline.tracks.indices {
            guard ti == gap.trackIndex || timeline.tracks[ti].syncLocked else { continue }
            let shifts = RippleEngine.computeRippleShiftsForRanges(
                clips: timeline.tracks[ti].clips,
                removedRanges: [gap.range]
            )
            // The gap track only ever moves clips into freed space; sync-locked followers may collide.
            if ti != gap.trackIndex, let reason = validateShifts(trackIndex: ti, shifts: shifts) {
                refuseRipple(reason: reason)
                return
            }
            shiftsByTrack[ti] = shifts
        }

        withTimelineSwap(actionName: "Ripple Delete") {
            for shifts in shiftsByTrack.values { applyShifts(shifts) }
        }
        selectedGap = nil
    }

    /// Ripple insert: add clips at `atFrame` and push everything past it right by the
    /// insertion's duration on the target track and every sync-locked track.
    @discardableResult
    func rippleInsertClips(assets: [MediaAsset], trackIndex: Int, atFrame: Int, segments: [String: ClosedRange<Double>] = [:]) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex) else { return [] }
        var created: [String] = []
        withTimelineSwap(actionName: "Ripple Insert Clips") {
            let totalPush = assets.reduce(0) { $0 + clipDurationFrames(for: $1, segment: segments[$1.id]) }

            for ti in timeline.tracks.indices where ti == trackIndex || timeline.tracks[ti].syncLocked {
                applyShifts(RippleEngine.computeRipplePush(
                    clips: timeline.tracks[ti].clips,
                    insertFrame: atFrame,
                    pushAmount: totalPush
                ))
            }
            created = createClips(from: assets, trackIndex: trackIndex, startFrame: atFrame, segments: segments)
            sortClips(trackIndex: trackIndex)
        }
        return created
    }

    struct RippleInsertSpec {
        let asset: MediaAsset
        let durationFrames: Int
        let trimStartFrame: Int?
        let trimEndFrame: Int?
    }

    /// Ripple insert with explicit per-clip duration and trim. Opens a gap at `atFrame`
    /// on the target track, every sync-locked track, and the audio track any linked
    /// audio lands on, then places the clips sequentially into the gap.
    @discardableResult
    func rippleInsertClips(specs: [RippleInsertSpec], trackIndex: Int, atFrame: Int) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex), !specs.isEmpty else { return [] }
        var created: [String] = []
        withTimelineSwap(actionName: specs.count == 1 ? "Ripple Insert Clip (Agent)" : "Ripple Insert Clips (Agent)") {
            let totalPush = specs.reduce(0) { $0 + $1.durationFrames }

            // Pin the linked-audio destination before pushing so it ripples too; otherwise the
            // auto-created audio partner would land on an un-pushed track and overlap.
            let targetIsVideo = timeline.tracks[trackIndex].type == .video
            let needsLinkedAudio = targetIsVideo && specs.contains { $0.asset.type == .video && $0.asset.hasAudio }
            let linkedAudioTrackIndex: Int? = needsLinkedAudio
                ? (timeline.tracks.firstIndex { $0.type == .audio } ?? insertTrack(at: timeline.tracks.count, type: .audio))
                : nil

            // Tracks the gap opens on. Splitting below doesn't add tracks, so these stay valid.
            let pushTracks = timeline.tracks.indices.filter {
                $0 == trackIndex || $0 == linkedAudioTrackIndex || timeline.tracks[$0].syncLocked
            }

            // Insert-edit: split any clip straddling atFrame on each pushed track so its right
            // half rides the ripple instead of being overlapped. splitClip also splits linked
            // partners and regroups them, so a clip already cut via its partner is no longer a
            // straddler when its own track comes up.
            for ti in pushTracks {
                if let straddler = timeline.tracks[ti].clips.first(where: { $0.startFrame < atFrame && atFrame < $0.endFrame }) {
                    _ = splitClip(clipId: straddler.id, atFrame: atFrame)
                }
            }

            for ti in pushTracks {
                applyShifts(RippleEngine.computeRipplePush(
                    clips: timeline.tracks[ti].clips, insertFrame: atFrame, pushAmount: totalPush
                ))
            }

            var cursor = atFrame
            for spec in specs {
                created.append(contentsOf: placeClip(
                    asset: spec.asset, trackIndex: trackIndex,
                    startFrame: cursor, durationFrames: spec.durationFrames,
                    linkedAudioTrackIndex: linkedAudioTrackIndex,
                    trimStartFrame: spec.trimStartFrame, trimEndFrame: spec.trimEndFrame
                ))
                cursor += spec.durationFrames
            }
        }
        return created
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
        timeline.tracks[ti].clips[loc.clipIndex].setDuration(newDuration)

        sortClips(trackIndex: ti)

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.trimClipInternal(clipId: clipId, trimStartFrame: prevStart, trimEndFrame: prevEnd)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Trim Clip")
        notifyTimelineChanged()
    }

    // MARK: - Validation

    /// Dry-run: returns a blocking reason (collision or negative startFrame) or nil if safe.
    fileprivate func validateShifts(trackIndex: Int, shifts: [ClipShift]) -> String? {
        guard !shifts.isEmpty, timeline.tracks.indices.contains(trackIndex) else { return nil }
        let track = timeline.tracks[trackIndex]
        let label = timelineTrackDisplayLabel(at: trackIndex)
        let shiftMap = Dictionary(uniqueKeysWithValues: shifts.map { ($0.clipId, $0.newStartFrame) })
        var intervals: [FrameRange] = []
        for clip in track.clips {
            let start = shiftMap[clip.id] ?? clip.startFrame
            if start < 0 {
                return "Sync-locked track \"\(label)\" would move past the timeline start."
            }
            intervals.append(FrameRange(start: start, end: start + clip.durationFrames))
        }
        intervals.sort { $0.start < $1.start }
        for i in 1..<intervals.count where intervals[i].start < intervals[i-1].end {
            return "Sync-locked track \"\(label)\" doesn't have room to ripple."
        }
        return nil
    }

    /// Refuse a ripple edit: beep + log.
    fileprivate func refuseRipple(reason: String) {
        NSSound.beep()
        Log.editor.notice("ripple blocked: \(reason)")
    }
}
