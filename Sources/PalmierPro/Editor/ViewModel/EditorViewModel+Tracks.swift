import AppKit

/// Track-level mutations: add/remove, visibility toggles, height, sync-lock.
extension EditorViewModel {

    // MARK: - Add / remove

    @discardableResult
    func insertTrack(at index: Int, type: ClipType) -> Int {
        let clamped = partitionedInsertionIndex(for: type, requested: index)
        let track = Track(type: type)
        withTimelineSwap(actionName: "Add Track") {
            timeline.tracks.insert(track, at: clamped)
        }
        return clamped
    }

    /// "V1", "A1", "I1" label for the track at the given index.
    func timelineTrackDisplayLabel(at trackIndex: Int) -> String {
        guard timeline.tracks.indices.contains(trackIndex) else { return "" }
        if timeline.tracks[trackIndex].isComp { return "Comp" }
        let type = timeline.tracks[trackIndex].type
        var n = 0
        if type == .audio {
            for i in 0...trackIndex where timeline.tracks[i].type == type {
                n += 1
            }
        } else {
            for i in trackIndex..<max(trackIndex + 1, zones.firstAudioIndex) where timeline.tracks[i].type == type {
                n += 1
            }
        }
        return "\(type.trackLabelPrefix)\(n)"
    }

    /// Clamp `requested` so that visual (video/image) tracks always sit above every audio track.
    private func partitionedInsertionIndex(for type: ClipType, requested: Int) -> Int {
        let z = zones
        let bounded = max(0, min(requested, z.trackCount))
        switch type {
        case .video, .image, .text, .lottie, .sequence:
            // Visual tracks must come at or before the first audio track.
            return min(bounded, z.firstAudioIndex)
        case .audio:
            // Audio tracks must come at or after the first audio track
            return max(bounded, z.firstAudioIndex)
        }
    }

    func removeTrack(id: String) {
        removeTracks(ids: [id])
    }

    // MARK: - Reorder
    /// Instantly move the track with `id` to `targetIndex`, clamped to its track type zone. No undo.
    func reorderTrackLive(id: String, to targetIndex: Int) {
        guard let from = timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        let z = zones
        let isAudio = timeline.tracks[from].type == .audio
        let lower = isAudio ? z.firstAudioIndex : 0
        let upper = isAudio ? z.trackCount - 1 : z.firstAudioIndex - 1
        let dest = max(lower, min(upper, targetIndex))
        guard dest != from else { return }
        let track = timeline.tracks.remove(at: from)
        timeline.tracks.insert(track, at: dest)
    }

    /// Register a single undo step for a completed live reorder.
    func commitTrackReorder(before: Timeline) {
        guard before != timeline else { return }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Reorder Track")
        notifyTimelineChanged()
    }

    func removeTracks(ids: [String]) {
        let set = Set(ids)
        guard timeline.tracks.contains(where: { set.contains($0.id) }) else { return }
        withTimelineSwap(actionName: set.count == 1 ? "Remove Track" : "Remove Tracks") {
            timeline.tracks.removeAll { set.contains($0.id) }
        }
    }

    func pruneEmptyTracks() {
        timeline.tracks.removeAll(where: \.clips.isEmpty)
    }

    // MARK: - Flag toggles

    func toggleTrackMute(trackIndex: Int) {
        toggleTrackFlag(trackIndex: trackIndex, keyPath: \.muted, onName: "Mute Track", offName: "Unmute Track")
    }

    func toggleTrackHidden(trackIndex: Int) {
        toggleTrackFlag(trackIndex: trackIndex, keyPath: \.hidden, onName: "Hide Track", offName: "Show Track")
    }

    /// Solo the track and its link-group partners as a unit. A plain click is exclusive —
    /// it replaces the current solo set, or clears it when this group is already the only solo.
    /// A Shift-click is additive, toggling just this group and leaving other solos in place.
    func toggleTrackSolo(trackIndex: Int, exclusive: Bool = true) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let group = soloGroupTrackIds(forTrackAt: trackIndex)
        let current = Set(timeline.tracks.filter(\.soloed).map(\.id))
        let groupSoloed = group.isSubset(of: current)

        let target: Set<String>
        let turningOff: Bool
        if exclusive {
            let isOnlySolo = current == group
            target = isOnlySolo ? [] : group
            turningOff = isOnlySolo
        } else if groupSoloed {
            target = current.subtracting(group)
            turningOff = true
        } else {
            target = current.union(group)
            turningOff = false
        }
        applySoloSet(target, actionName: turningOff ? "Unsolo Track" : "Solo Track")
    }

    /// Declarative solo used by the Agent: set this track and its link-group partners on or off,
    /// without disturbing other tracks' solo state.
    func setTrackSolo(trackIndex: Int, soloed: Bool) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let group = soloGroupTrackIds(forTrackAt: trackIndex)
        let current = Set(timeline.tracks.filter(\.soloed).map(\.id))
        let target = soloed ? current.union(group) : current.subtracting(group)
        applySoloSet(target, actionName: soloed ? "Solo Track" : "Unsolo Track")
    }

    /// Track ids that solo together: the target plus any track sharing a clip `linkGroupId` with it.
    private func soloGroupTrackIds(forTrackAt index: Int) -> Set<String> {
        guard timeline.tracks.indices.contains(index) else { return [] }
        let target = timeline.tracks[index]
        var ids: Set<String> = [target.id]
        let targetLinkIds = Set(target.clips.compactMap(\.linkGroupId))
        guard !targetLinkIds.isEmpty else { return ids }
        for t in timeline.tracks where t.id != target.id {
            if t.clips.contains(where: { $0.linkGroupId.map(targetLinkIds.contains) ?? false }) {
                ids.insert(t.id)
            }
        }
        return ids
    }

    /// Set every track's `soloed` flag to match `soloedIds` in one undoable step. No-op when unchanged.
    private func applySoloSet(_ soloedIds: Set<String>, actionName: String) {
        withTimelineSwap(actionName: actionName) {
            for i in timeline.tracks.indices {
                timeline.tracks[i].soloed = soloedIds.contains(timeline.tracks[i].id)
            }
        }
    }

    // MARK: - Solo (derived audition state)

    /// True when any track in the requested zone is soloed.
    func isAnySoloActive(inAudioZone: Bool) -> Bool {
        timeline.isAnySoloActive(inAudioZone: inAudioZone)
    }

    /// Visual track hidden by its own flag or excluded by a video-zone solo. Derived — never stored.
    func effectiveHidden(for track: Track) -> Bool {
        timeline.effectiveHidden(for: track)
    }

    /// Audio track silenced by its own flag or by an active solo it isn't part of. Derived — never stored.
    func effectiveMuted(for track: Track) -> Bool {
        timeline.effectiveMuted(for: track)
    }

    func toggleTrackSyncLock(trackIndex: Int) {
        if timeline.tracks.indices.contains(trackIndex),
           timeline.tracks[trackIndex].syncLocked,
           let clip = timeline.tracks[trackIndex].clips.first(where: { $0.multicamGroupId != nil }),
           let group = multicamGroup(of: clip) {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Can't unlock sync on a multicam track — \"\(group.name)\" stays aligned through it."))
            NSSound.beep()
            return
        }
        toggleTrackFlag(trackIndex: trackIndex, keyPath: \.syncLocked, onName: "Sync Lock Track", offName: "Unlock Track Sync")
    }

    /// Flip a `Bool` on a track, register a reversing undo, and publish the change.
    /// `onName` is used when the flag transitions false → true; `offName` for true → false.
    private func toggleTrackFlag(
        trackIndex: Int,
        keyPath: WritableKeyPath<Track, Bool>,
        onName: String,
        offName: String
    ) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let trackId = timeline.tracks[trackIndex].id
        let was = timeline.tracks[trackIndex][keyPath: keyPath]
        timeline.tracks[trackIndex][keyPath: keyPath].toggle()
        let actionName = was ? offName : onName
        registerTimelineUndo(actionName) { vm in
            guard let i = vm.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
            vm.timeline.tracks[i][keyPath: keyPath] = was
        }
        notifyTimelineChanged()
    }

    // MARK: - Sizing

    func setTrackHeight(trackIndex: Int, height: CGFloat) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let trackId = timeline.tracks[trackIndex].id
        let prev = timeline.tracks[trackIndex].displayHeight
        timeline.tracks[trackIndex].displayHeight = max(TrackSize.minHeight, min(TrackSize.maxHeight, height))
        registerTimelineUndo("Resize Track") { vm in
            guard let i = vm.timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
            vm.setTrackHeight(trackIndex: i, height: prev)
        }
    }
}
