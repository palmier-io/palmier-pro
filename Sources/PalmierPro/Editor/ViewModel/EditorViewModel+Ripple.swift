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

/// Ripple editing syncs trims, deletes, and inserts across tracks.
extension EditorViewModel {

    // MARK: - Public API

    /// Trim clips as a batch, keeping linked clips trimmed together.
    func trimClips(_ edits: [(clipId: String, trimStartFrame: Int, trimEndFrame: Int)]) {
        guard !edits.isEmpty else { return }
        let batchIds = Set(edits.map(\.clipId))
        undoManager?.beginUndoGrouping()
        for e in edits {
            trimClipInternal(clipId: e.clipId, trimStartFrame: e.trimStartFrame, trimEndFrame: e.trimEndFrame, protecting: batchIds)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(edits.count == 1 ? "Trim Clip" : "Trim Clips")
    }

    /// Ripple trim result: resized clips, shifted clips, and optional obstacle frame if clamped.
    struct RippleTrimPlan {
        struct Resize { let clipId: String; let trimStart: Int; let trimEnd: Int; let duration: Int }
        let durationDelta: Int
        let resizes: [Resize]
        let shifts: [ClipShift]
        let blockedAtFrame: Int?
        var targetIds: Set<String> { Set(resizes.map(\.clipId)) }
    }

    /// Plans a non-destructive ripple trim, capped by the strictest linked or sync-locked constraint
    func planRippleTrim(clipId: String, edge: TrimEdge, deltaFrames: Int, propagateToLinked: Bool) -> RippleTrimPlan? {
        guard deltaFrames != 0, let leadLoc = findClip(id: clipId) else { return nil }
        let leadEnd = timeline.tracks[leadLoc.trackIndex].clips[leadLoc.clipIndex].endFrame

        var targets: [String] = [clipId]
        if propagateToLinked { targets.append(contentsOf: linkedPartnerIds(of: clipId)) }
        let targetIds = Set(targets)
        let targetClips = targets.compactMap { findClip(id: $0).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }

        // Each target's own source headroom caps how far it can ripple; bind to the smallest.
        let sourceDelta = targetClips
            .map { rippleTrimDurationDelta(for: $0, edge: edge, delta: deltaFrames) }
            .min(by: { abs($0) < abs($1) }) ?? 0

        // Shrinking shifts sync-locked followers left; clamp to the tightest available room.
        var durationDelta = sourceDelta
        var blockedAtFrame: Int?
        if sourceDelta < 0 {
            let limits = timeline.tracks.compactMap { track -> (room: Int, obstacle: Int)? in
                guard track.syncLocked, !track.clips.contains(where: { targetIds.contains($0.id) }) else { return nil }
                return syncLockedLeftRoom(track: track, insertFrame: leadEnd)
            }
            if let tightest = limits.min(by: { $0.room < $1.room }), sourceDelta < -tightest.room {
                durationDelta = -tightest.room
                blockedAtFrame = tightest.obstacle
            }
        }
        guard durationDelta != 0 || blockedAtFrame != nil else { return nil }

        // A right-edge duration change maps to the same source-frame edge drag; left flips sign.
        let resizes = targetClips.map { c -> RippleTrimPlan.Resize in
            let fields = trimValues(for: c, edge: edge, delta: edge == .right ? durationDelta : -durationDelta)
            return .init(clipId: c.id, trimStart: fields.trimStart, trimEnd: fields.trimEnd,
                         duration: max(1, c.durationFrames + durationDelta))
        }

        var shifts: [ClipShift] = []
        for ti in timeline.tracks.indices {
            let track = timeline.tracks[ti]
            let targetEnd = track.clips.first { targetIds.contains($0.id) }?.endFrame
            guard targetEnd != nil || track.syncLocked else { continue }
            shifts += RippleEngine.computeRipplePush(
                clips: track.clips, insertFrame: targetEnd ?? leadEnd, pushAmount: durationDelta, excludeIds: targetIds
            )
        }
        return RippleTrimPlan(durationDelta: durationDelta, resizes: resizes, shifts: shifts, blockedAtFrame: blockedAtFrame)
    }

    /// Max left shift for sync-locked clips before hitting the next obstacle; nil if no shift possible.
    private func syncLockedLeftRoom(track: Track, insertFrame: Int) -> (room: Int, obstacle: Int)? {
        guard let first = track.clips.filter({ $0.startFrame >= insertFrame }).map(\.startFrame).min() else { return nil }
        let prevEnd = track.clips.filter { $0.startFrame < insertFrame }.map(\.endFrame).max() ?? 0
        return (max(0, first - prevEnd), prevEnd)
    }

    /// Ripple trim: resize a clip from the dragged edge and shift every clip after it
    func rippleTrimClip(clipId: String, edge: TrimEdge, deltaFrames: Int, propagateToLinked: Bool) {
        if let loc = findClip(id: clipId) {
            let lead = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            var trimShifting = Set(timeline.tracks.filter(\.syncLocked).map(\.id))
            trimShifting.insert(timeline.tracks[loc.trackIndex].id)
            let shiftPoint = edge == .left ? lead.startFrame : lead.endFrame
            if let reason = multicamManualRippleViolation(shiftingTrackIds: trimShifting, atFrame: shiftPoint) {
                refuseRipple(reason: reason)
                return
            }
        }
        guard let plan = planRippleTrim(clipId: clipId, edge: edge, deltaFrames: deltaFrames, propagateToLinked: propagateToLinked) else { return }

        let touched = plan.targetIds.union(plan.shifts.map(\.clipId))
        withTimelineSwap(actionName: "Ripple Trim") {
            for r in plan.resizes {
                guard let l = findClip(id: r.clipId) else { continue }
                timeline.tracks[l.trackIndex].clips[l.clipIndex].trimStartFrame = r.trimStart
                timeline.tracks[l.trackIndex].clips[l.clipIndex].trimEndFrame = r.trimEnd
                timeline.tracks[l.trackIndex].clips[l.clipIndex].setDuration(r.duration)
            }
            applyShifts(plan.shifts)
            for ti in timeline.tracks.indices where timeline.tracks[ti].clips.contains(where: { touched.contains($0.id) }) {
                sortClips(trackIndex: ti)
            }
        }
    }

    /// Timeline delta from a ripple trim of `clip` by `delta` frames.
    private func rippleTrimDurationDelta(for clip: Clip, edge: TrimEdge, delta: Int) -> Int {
        let fields = trimValues(for: clip, edge: edge, delta: delta)
        let sourceShift = (fields.trimStart - clip.trimStartFrame) + (fields.trimEnd - clip.trimEndFrame)
        return -Int((Double(sourceShift) / clip.speed).rounded())
    }

    /// Ripple delete: remove selected clips and shift sync-locked tracks to keep them aligned.
    func rippleDeleteSelectedClips() {
        let ids = selectedClipIds
        guard !ids.isEmpty else { return }

        // Merged ranges used to shift sync-locked tracks that have no deletions of their own.
        let globalRemovedRanges: [FrameRange] = timeline.tracks
            .flatMap(\.clips)
            .filter { ids.contains($0.id) }
            .map { FrameRange(start: $0.startFrame, end: $0.endFrame) }

        let shiftingIds = Set(timeline.tracks.filter { t in
            t.syncLocked || t.clips.contains { ids.contains($0.id) }
        }.map(\.id))
        for range in globalRemovedRanges {
            if let reason = multicamManualRippleViolation(shiftingTrackIds: shiftingIds, atFrame: range.end) {
                refuseRipple(reason: reason)
                return
            }
        }

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

        withTimelineSwap(actionName: "Ripple Delete", refreshVisuals: false) {
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

    /// Ripple-deletes frame ranges on a track, including linked and sync-locked tracks. Tracks in `ignoreSyncLockTrackIndices` are unlocked for this call.
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
        for track in timeline.tracks where track.syncLocked && !ignoredTrackIds.contains(track.id) {
            clearTrackIds.insert(track.id)
        }
        // Ensure all linked partners of affected clips are included to keep A/V in sync.
        var frontier = clearTrackIds
        while !frontier.isEmpty {
            var added: Set<String> = []
            for tid in frontier {
                guard let ti = timeline.tracks.firstIndex(where: { $0.id == tid }) else { continue }
                for clip in timeline.tracks[ti].clips
                where clip.linkGroupId != nil && merged.contains(where: { $0.start < clip.endFrame && $0.end > clip.startFrame }) {
                    for pid in linkedPartnerIds(of: clip.id) {
                        guard let l = findClip(id: pid) else { continue }
                        let partnerTid = timeline.tracks[l.trackIndex].id
                        if clearTrackIds.insert(partnerTid).inserted { added.insert(partnerTid) }
                    }
                }
            }
            frontier = added
        }

        let shiftingIds = clearTrackIds.union(
            timeline.tracks.filter { $0.syncLocked && !ignoredTrackIds.contains($0.id) }.map(\.id)
        )
        if let reason = multicamAtomicityViolation(shiftingTrackIds: shiftingIds) {
            mediaPanelToast = MediaPanelToast(stringLiteral: reason)
            return .refused(reason)
        }

        // Refuse up front if a sync-locked follower can't absorb the shift after clearing.
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

        let gapShiftingIds = Set(timeline.tracks.indices
            .filter { $0 == gap.trackIndex || timeline.tracks[$0].syncLocked }
            .map { timeline.tracks[$0].id })
        if let reason = multicamManualRippleViolation(shiftingTrackIds: gapShiftingIds, atFrame: gap.range.end) {
            refuseRipple(reason: reason)
            return
        }

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
        if let reason = multicamManualRippleViolation(shiftingTrackIds: rippleInsertShiftingTrackIds(trackIndex: trackIndex), atFrame: atFrame) {
            refuseRipple(reason: reason)
            return []
        }
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

    struct RippleInsertPreviewPlan: Equatable {
        let gapRangesByTrackIndex: [Int: FrameRange]
        let newTrackGapRangesByTarget: [TrackDropTarget: FrameRange]
        let shiftDeltasByClipId: [String: Int]
    }

    func planRippleInsertPreview(dropPlan plan: DropPlan, atFrame: Int) -> RippleInsertPreviewPlan? {
        var gapLengthsByTrackIndex: [Int: Int] = [:]
        var newTrackGapLengthsByTarget: [TrackDropTarget: Int] = [:]
        var shiftDeltasByClipId: [String: Int] = [:]

        func currentTrackIndex(for target: TrackDropTarget, shiftedBy visualTarget: TrackDropTarget?) -> Int? {
            guard case .existingTrack(var index) = target else { return nil }
            if case .newTrackAt(let visualInsertIndex) = visualTarget,
               index > visualInsertIndex {
                index -= 1
            }
            return timeline.tracks.indices.contains(index) ? index : nil
        }

        func affectedTrackIndexes(for target: TrackDropTarget, shiftedBy visualTarget: TrackDropTarget?) -> Set<Int> {
            var indexes = Set(timeline.tracks.indices.filter { timeline.tracks[$0].syncLocked })
            if let index = currentTrackIndex(for: target, shiftedBy: visualTarget) {
                indexes.insert(index)
            }
            return indexes
        }

        func addPush(target: TrackDropTarget?, shiftedBy visualTarget: TrackDropTarget?, pushAmount: Int) {
            guard let target, pushAmount > 0 else { return }
            if case .newTrackAt = target {
                newTrackGapLengthsByTarget[target, default: 0] += pushAmount
            }
            for trackIndex in affectedTrackIndexes(for: target, shiftedBy: visualTarget) {
                let clips = timeline.tracks[trackIndex].clips
                let startFramesByClipId = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.startFrame) })
                let shifts = RippleEngine.computeRipplePush(clips: clips, insertFrame: atFrame, pushAmount: pushAmount)
                for shift in shifts {
                    guard let originalStartFrame = startFramesByClipId[shift.clipId] else { continue }
                    shiftDeltasByClipId[shift.clipId, default: 0] += shift.newStartFrame - originalStartFrame
                }
                gapLengthsByTrackIndex[trackIndex, default: 0] += pushAmount
            }
        }

        addPush(target: plan.visualTarget, shiftedBy: nil, pushAmount: plan.visualDurationFrames)
        addPush(target: audioTargetAfterVisualInsertion(plan: plan), shiftedBy: plan.visualTarget, pushAmount: plan.audioOnlyDurationFrames)

        guard !gapLengthsByTrackIndex.isEmpty || !newTrackGapLengthsByTarget.isEmpty || !shiftDeltasByClipId.isEmpty else { return nil }
        let gapRangesByTrackIndex = gapLengthsByTrackIndex.mapValues {
            FrameRange(start: atFrame, end: atFrame + $0)
        }
        let newTrackGapRangesByTarget = newTrackGapLengthsByTarget.mapValues {
            FrameRange(start: atFrame, end: atFrame + $0)
        }
        return RippleInsertPreviewPlan(
            gapRangesByTrackIndex: gapRangesByTrackIndex,
            newTrackGapRangesByTarget: newTrackGapRangesByTarget,
            shiftDeltasByClipId: shiftDeltasByClipId
        )
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
        if let reason = multicamManualRippleViolation(shiftingTrackIds: rippleInsertShiftingTrackIds(trackIndex: trackIndex), atFrame: atFrame) {
            refuseRipple(reason: reason)
            return []
        }
        var created: [String] = []
        withTimelineSwap(actionName: specs.count == 1 ? "Ripple Insert Clip (Agent)" : "Ripple Insert Clips (Agent)") {
            let totalPush = specs.reduce(0) { $0 + $1.durationFrames }

            // Pin the linked-audio destination before pushing so it ripples too; otherwise the
            // auto-created audio partner would land on an un-pushed track and overlap.
            let targetIsVideo = timeline.tracks[trackIndex].type == .video
            let needsLinkedAudio = targetIsVideo && specs.contains {
                $0.asset.hasAudio && ($0.asset.type == .video || $0.asset.type == .sequence)
            }
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

    fileprivate func trimClipInternal(clipId: String, trimStartFrame: Int, trimEndFrame: Int, protecting: Set<String> = []) {
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

        let prevStartFrame = clip.startFrame
        let prevEndFrame = clip.endFrame
        let newEndFrame = newStartFrame + newDuration
        let protected = protecting.union([clipId])
        if newStartFrame < prevStartFrame {
            clearRegion(trackIndex: ti, start: newStartFrame, end: prevStartFrame, prune: false, excluding: protected)
        }
        if newEndFrame > prevEndFrame {
            clearRegion(trackIndex: ti, start: prevEndFrame, end: newEndFrame, prune: false, excluding: protected)
        }

        guard let loc = findClip(id: clipId) else {
            undoManager?.endUndoGrouping()
            return
        }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimStartFrame = trimStartFrame
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimEndFrame = trimEndFrame
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = newStartFrame
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].setDuration(newDuration)

        sortClips(trackIndex: loc.trackIndex)

        registerTimelineUndo { vm in
            vm.trimClipInternal(clipId: clipId, trimStartFrame: prevStart, trimEndFrame: prevEnd, protecting: protecting)
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
        mediaPanelToast = MediaPanelToast(stringLiteral: reason)
        NSSound.beep()
        Log.editor.notice("ripple blocked: \(reason)")
    }

    // MARK: - Multicam atomicity

    fileprivate func rippleInsertShiftingTrackIds(trackIndex: Int) -> Set<String> {
        Set(timeline.tracks.indices
            .filter { $0 == trackIndex || timeline.tracks[$0].syncLocked }
            .map { timeline.tracks[$0].id })
    }

    func multicamManualRippleViolation(shiftingTrackIds: Set<String>, atFrame frame: Int) -> String? {
        if let reason = multicamAtomicityViolation(shiftingTrackIds: shiftingTrackIds) { return reason }
        for track in timeline.tracks where shiftingTrackIds.contains(track.id) {
            if let clip = track.clips.first(where: {
                $0.multicamGroupId != nil && $0.startFrame < frame && $0.endFrame > frame
            }), let group = multicamGroup(of: clip) {
                return "Can't ripple through multicam group \"\(group.name)\" — split its clips at the edit point, or remove silence/words to cut time."
            }
        }
        return nil
    }

    func multicamAtomicityViolation(shiftingTrackIds: Set<String>) -> String? {
        var groupTracks: [String: Set<String>] = [:]
        for track in timeline.tracks {
            for gid in Set(track.clips.compactMap(\.multicamGroupId)) {
                groupTracks[gid, default: []].insert(track.id)
            }
        }
        for (gid, trackIds) in groupTracks {
            let moving = trackIds.intersection(shiftingTrackIds)
            guard !moving.isEmpty, moving != trackIds else { continue }
            let name = multicamGroup(id: gid)?.name ?? "Multicam"
            let stranded = timeline.tracks.indices
                .filter { !shiftingTrackIds.contains(timeline.tracks[$0].id) && trackIds.contains(timeline.tracks[$0].id) }
                .map { timelineTrackDisplayLabel(at: $0) }
            return "Can't shift part of multicam group \"\(name)\" — \(stranded.joined(separator: ", ")) would stay behind and desync."
        }
        return nil
    }
}
