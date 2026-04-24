import AppKit

/// Track-level mutations: add/remove, visibility toggles, height, sync-lock.
extension EditorViewModel {

    // MARK: - Add / remove

    @discardableResult
    func insertTrack(at index: Int, type: ClipType, label: String) -> Int {
        let track = Track(type: type, label: label)
        let clamped = partitionedInsertionIndex(for: type, requested: index)
        timeline.tracks.insert(track, at: clamped)
        undoManager?.registerUndo(withTarget: self) { $0.removeTrack(id: track.id) }
        undoManager?.setActionName("Add Track")
        return clamped
    }

    /// Clamp `requested` so that visual (video/image) tracks always sit above every audio track.
    private func partitionedInsertionIndex(for type: ClipType, requested: Int) -> Int {
        let z = zones
        let bounded = max(0, min(requested, z.trackCount))
        switch type {
        case .video, .image, .text:
            // Visual tracks must come at or before the first audio track.
            return min(bounded, z.firstAudioIndex)
        case .audio:
            // Audio tracks must come at or after the first audio track
            return max(bounded, z.firstAudioIndex)
        }
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

    func pruneEmptyTracks() {
        timeline.tracks.filter(\.clips.isEmpty).forEach { removeTrack(id: $0.id) }
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
        undoManager?.registerUndo(withTarget: self) { vm in
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
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setTrackHeight(trackIndex: trackIndex, height: prev)
        }
        undoManager?.setActionName("Resize Track")
    }
}
