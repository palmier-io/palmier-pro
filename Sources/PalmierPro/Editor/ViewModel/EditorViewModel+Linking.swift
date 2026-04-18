import AppKit

/// Snapshot of the video/audio track partition. Video/image tracks sit at
/// indices `[0, firstAudioIndex)`; audio tracks at `[firstAudioIndex, trackCount)`.
struct ZoneLayout {
    let trackCount: Int
    let firstAudioIndex: Int
    var videoTrackCount: Int { firstAudioIndex }
    var audioTrackCount: Int { trackCount - firstAudioIndex }
}

/// Link groups: clips that share a `linkGroupId` behave as one unit for selection, move, trim, and delete.
extension EditorViewModel {

    // MARK: - Indexes

    /// Reverse link-group index — built in a single O(tracks·clips) pass.
    var linkIndex: [String: [String]] {
        var m: [String: [String]] = [:]
        for t in timeline.tracks {
            for c in t.clips {
                if let g = c.linkGroupId { m[g, default: []].append(c.id) }
            }
        }
        return m
    }

    /// Video/audio zone partition.
    var zones: ZoneLayout {
        let count = timeline.tracks.count
        let firstAudio = timeline.tracks.firstIndex(where: { $0.type == .audio }) ?? count
        return ZoneLayout(trackCount: count, firstAudioIndex: firstAudio)
    }

    // MARK: - Group lookup

    /// Returns every clip id sharing a link group with any id in `ids`,
    /// including the inputs themselves.
    func expandToLinkGroup(_ ids: Set<String>) -> Set<String> {
        let idx = linkIndex
        var clipToGroup: [String: String] = [:]
        for (gid, members) in idx {
            for id in members { clipToGroup[id] = gid }
        }
        var groups = Set<String>()
        for id in ids {
            if let g = clipToGroup[id] { groups.insert(g) }
        }
        guard !groups.isEmpty else { return ids }
        var result = ids
        for g in groups {
            if let members = idx[g] { result.formUnion(members) }
        }
        return result
    }

    /// Ids of clips that share `clip`'s link group, excluding `clip` itself.
    func linkedPartnerIds(of clipId: String) -> [String] {
        for (_, members) in linkIndex where members.contains(clipId) {
            return members.filter { $0 != clipId }
        }
        return []
    }

    // MARK: - Out-of-sync offset

    /// Batch-compute out-of-sync offsets for every linked clip in a single
    /// pass. Clips in sync (or unlinked) are absent from the returned map.
    func linkGroupOffsets() -> [String: Int] {
        var byGroup: [String: [(id: String, start: Int)]] = [:]
        for track in timeline.tracks {
            for clip in track.clips {
                guard let gid = clip.linkGroupId else { continue }
                byGroup[gid, default: []].append((clip.id, clip.startFrame - clip.trimStartFrame))
            }
        }
        var offsets: [String: Int] = [:]
        for (_, entries) in byGroup where entries.count > 1 {
            let ref = entries.lazy.map(\.start).min()!
            for entry in entries {
                let delta = entry.start - ref
                if delta != 0 { offsets[entry.id] = delta }
            }
        }
        return offsets
    }

    // MARK: - Link / Unlink commands

    /// Stamp a new `linkGroupId` on every clip in `ids`, merging pre-existing sub-groups into the new group.
    func linkClips(ids: Set<String>) {
        guard ids.count >= 2 else { return }
        let newGroup = UUID().uuidString
        mutateClips(ids: ids, actionName: "Link") { $0.linkGroupId = newGroup }
    }

    /// Clear `linkGroupId` on every clip that shares a group with any id in `ids`.
    func unlinkClips(ids: Set<String>) {
        let expanded = expandToLinkGroup(ids).filter { id in
            guard let loc = findClip(id: id) else { return false }
            return timeline.tracks[loc.trackIndex].clips[loc.clipIndex].linkGroupId != nil
        }
        mutateClips(ids: Set(expanded), actionName: "Unlink") { $0.linkGroupId = nil }
        selectedClipIds.removeAll()
    }

    // MARK: - Trim with linked propagation

    enum TrimEdge {
        case left, right
    }

    /// Apply a trim-drag commit. Expands the edit set to linked partners when `propagateToLinked` is on and hands off to `trimClips`.
    func commitTrim(clipId: String, edge: TrimEdge, deltaFrames: Int, propagateToLinked: Bool) {
        guard let loc = findClip(id: clipId) else { return }
        let leadClip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let leadNew = trimValues(for: leadClip, edge: edge, delta: deltaFrames)
        var edits: [(clipId: String, trimStartFrame: Int, trimEndFrame: Int)] = [
            (clipId, leadNew.trimStart, leadNew.trimEnd)
        ]
        if propagateToLinked {
            for partnerId in linkedPartnerIds(of: clipId) {
                guard let pLoc = findClip(id: partnerId) else { continue }
                let partner = timeline.tracks[pLoc.trackIndex].clips[pLoc.clipIndex]
                let p = trimValues(for: partner, edge: edge, delta: deltaFrames)
                edits.append((partnerId, p.trimStart, p.trimEnd))
            }
        }
        trimClips(edits)
    }

    private func trimValues(for clip: Clip, edge: TrimEdge, delta: Int) -> (trimStart: Int, trimEnd: Int) {
        switch edge {
        case .left:
            return (max(0, clip.trimStartFrame + delta), clip.trimEndFrame)
        case .right:
            return (clip.trimStartFrame, max(0, clip.trimEndFrame - delta))
        }
    }

    // MARK: - Track-zone routing for drops

    /// Index of the topmost video/image track, or nil if none exist.
    var topVisualTrackIndex: Int? {
        let z = zones
        return z.videoTrackCount > 0 ? 0 : nil
    }

    /// First audio track with no overlap at [startFrame, startFrame+duration), else nil.
    func availableAudioTrackIndex(startFrame: Int, duration: Int) -> Int? {
        let z = zones
        for i in z.firstAudioIndex..<z.trackCount {
            let track = timeline.tracks[i]
            let conflicts = track.clips.contains { c in
                !(c.endFrame <= startFrame || c.startFrame >= startFrame + duration)
            }
            if !conflicts { return i }
        }
        return nil
    }

    /// Where the visual half of a drop lands. Cursor in the audio zone mirrors
    /// around the divider so moving the cursor down there pushes the ghost up.
    func resolveVisualDropTarget(cursor: TrackDropTarget) -> TrackDropTarget {
        let z = zones

        if z.trackCount == 0 { return .newTrackAt(0) }

        switch cursor {
        case .existingTrack(let idx):
            guard timeline.tracks.indices.contains(idx) else { return .newTrackAt(0) }
            if timeline.tracks[idx].type != .audio {
                return .existingTrack(idx)
            }
            let distance = idx - z.firstAudioIndex
            let mirrored = z.firstAudioIndex - 1 - distance
            if (0..<z.firstAudioIndex).contains(mirrored) {
                return .existingTrack(mirrored)
            }
            if let v = topVisualTrackIndex { return .existingTrack(v) }
            return .newTrackAt(0)
        case .newTrackAt(let insertIdx):
            if insertIdx <= z.firstAudioIndex {
                return .newTrackAt(insertIdx)
            }
            let distance = insertIdx - z.firstAudioIndex
            return .newTrackAt(max(0, z.firstAudioIndex - distance))
        }
    }

    /// Where the audio half of a drop lands. Always route to the cursor-indicated track (audio itself or its mirror across the divider), even if there's content there.
    func resolveAudioDropTarget(cursor: TrackDropTarget) -> TrackDropTarget {
        let z = zones

        if z.trackCount == 0 { return .newTrackAt(1) }

        // newTrackAt cursor: compute the clamped insertion index directly.
        if case .newTrackAt(let insertIdx) = cursor {
            if insertIdx > z.firstAudioIndex {
                return .newTrackAt(insertIdx)
            }
            let distance = z.firstAudioIndex - insertIdx
            let clamped = min(distance, z.audioTrackCount)
            return .newTrackAt(z.firstAudioIndex + clamped)
        }

        if let idx = preferredAudioTrack(cursor: cursor) {
            return .existingTrack(idx)
        }
        // No audio tracks exist yet — create one at the bottom.
        return .newTrackAt(z.trackCount)
    }

    /// The audio track the cursor points at: the track itself if audio, else
    /// the mirrored audio track across the zone divider (V1 ↔ A1, V2 ↔ A2).
    private func preferredAudioTrack(cursor: TrackDropTarget) -> Int? {
        guard case .existingTrack(let idx) = cursor,
              timeline.tracks.indices.contains(idx) else { return nil }
        let z = zones
        guard z.audioTrackCount > 0 else { return nil }
        if timeline.tracks[idx].type == .audio { return idx }
        let distanceFromDivider = z.firstAudioIndex - 1 - idx
        let mirrored = z.firstAudioIndex + distanceFromDivider
        return (z.firstAudioIndex..<z.trackCount).contains(mirrored) ? mirrored : z.firstAudioIndex
    }

    /// Bump an audio target by +1 when a preceding visual insertion lands at-or-before it, so the resolved (current-state) index still points at the right slot post-insertion.
    func shiftAfterVisualInsertion(audio: TrackDropTarget, visual: TrackDropTarget) -> TrackDropTarget {
        guard case .newTrackAt(let visualInsertIdx) = visual else { return audio }
        switch audio {
        case .existingTrack(let idx):
            return idx >= visualInsertIdx ? .existingTrack(idx + 1) : audio
        case .newTrackAt(let idx):
            return idx >= visualInsertIdx ? .newTrackAt(idx + 1) : audio
        }
    }

    // MARK: - DropPlan

    /// Resolved drop target for a set of assets
    struct DropPlan {
        let placements: [Placement]
        let visualTarget: TrackDropTarget?
        let audioTarget: TrackDropTarget?

        struct Placement {
            let asset: MediaAsset
            let startFrame: Int
            let durationFrames: Int
            let hasVisual: Bool
            let hasAudio: Bool
        }
    }

    /// Compute the ghost+commit plan for dropping `assets` at `atFrame` with the cursor over `cursor`.
    func resolveDropPlan(cursor: TrackDropTarget, assets: [MediaAsset], atFrame: Int) -> DropPlan {
        let fps = timeline.fps
        var placements: [DropPlan.Placement] = []
        var c = atFrame
        for asset in assets {
            let dur = max(1, secondsToFrame(seconds: asset.duration, fps: fps))
            let hasVisual = asset.type.isVisual
            let hasAudio = asset.type == .audio || (asset.type == .video && asset.hasAudio)
            placements.append(.init(
                asset: asset, startFrame: c, durationFrames: dur,
                hasVisual: hasVisual, hasAudio: hasAudio
            ))
            c += dur
        }
        let hasAnyVisual = placements.contains(where: \.hasVisual)
        let hasAnyAudio = placements.contains(where: \.hasAudio)
        let visualTarget = hasAnyVisual ? resolveVisualDropTarget(cursor: cursor) : nil
        let audioTarget = hasAnyAudio ? resolveAudioDropTarget(cursor: cursor) : nil
        return DropPlan(placements: placements, visualTarget: visualTarget, audioTarget: audioTarget)
    }

    func materialize(plan: DropPlan) -> (visual: Int?, audio: Int?) {
        let visualIdx = plan.visualTarget.map { materializeTrackIndex(target: $0, type: .video) }
        let audioIdx: Int? = plan.audioTarget.map { audio in
            let shifted = plan.visualTarget.map { shiftAfterVisualInsertion(audio: audio, visual: $0) } ?? audio
            return materializeTrackIndex(target: shifted, type: .audio)
        }
        return (visualIdx, audioIdx)
    }

    /// Resolve a `TrackDropTarget` into a concrete track index, creating a new track if needed.
    func materializeTrackIndex(target: TrackDropTarget, type: ClipType) -> Int {
        switch target {
        case .existingTrack(let idx):
            return idx
        case .newTrackAt(let idx):
            return insertTrack(at: idx, type: type, label: type.trackLabel)
        }
    }

    func resolveOrCreateAudioTrack(startFrame: Int, duration: Int) -> Int {
        if let i = availableAudioTrackIndex(startFrame: startFrame, duration: duration) {
            return i
        }
        return insertTrack(at: timeline.tracks.count, type: .audio, label: ClipType.audio.trackLabel)
    }

    // MARK: - Context-menu enablement

    var canUnlinkSelected: Bool {
        for track in timeline.tracks {
            for clip in track.clips where selectedClipIds.contains(clip.id) && clip.linkGroupId != nil {
                return true
            }
        }
        return false
    }

    var canLinkSelected: Bool {
        guard selectedClipIds.count >= 2 else { return false }
        var types = Set<ClipType>()
        var groups = Set<String>()
        var ungrouped = 0
        for track in timeline.tracks {
            for clip in track.clips where selectedClipIds.contains(clip.id) {
                types.insert(clip.mediaType)
                if let gid = clip.linkGroupId { groups.insert(gid) } else { ungrouped += 1 }
            }
        }
        guard types.count >= 2 else { return false }
        // Already all in one group → nothing to do
        return !(groups.count == 1 && ungrouped == 0)
    }
}
