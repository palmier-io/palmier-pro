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
        case .video, .image, .text, .lottie:
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

    func toggleTrackSyncLock(trackIndex: Int) {
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
        let was = timeline.tracks[trackIndex][keyPath: keyPath]
        timeline.tracks[trackIndex][keyPath: keyPath].toggle()
        registerTimelineUndo { vm in
            vm.timeline.tracks[trackIndex][keyPath: keyPath] = was
        }
        undoManager?.setActionName(was ? offName : onName)
        notifyTimelineChanged()
    }

    // MARK: - Sizing

    func setTrackHeight(trackIndex: Int, height: CGFloat) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let prev = timeline.tracks[trackIndex].displayHeight
        timeline.tracks[trackIndex].displayHeight = max(TrackSize.minHeight, min(TrackSize.maxHeight, height))
        registerTimelineUndo { vm in
            vm.setTrackHeight(trackIndex: trackIndex, height: prev)
        }
        undoManager?.setActionName("Resize Track")
    }
}
