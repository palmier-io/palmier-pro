extension EditorViewModel {
    enum SelectForwardScope {
        case track
        case allTracks
    }

    func selectForwardFromCurrentSelection(scope: SelectForwardScope) {
        guard let anchorId = forwardSelectionAnchorId() else { return }
        selectForward(from: anchorId, scope: scope)
    }

    func selectForward(from clipId: String, scope: SelectForwardScope) {
        guard let anchorLoc = findClip(id: clipId) else { return }
        let anchorClip = timeline.tracks[anchorLoc.trackIndex].clips[anchorLoc.clipIndex]
        var ids: Set<String> = []

        for (trackIndex, track) in timeline.tracks.enumerated() {
            guard scope == .allTracks || trackIndex == anchorLoc.trackIndex else { continue }
            for clip in track.clips where clip.startFrame >= anchorClip.startFrame {
                ids.insert(clip.id)
            }
        }

        selectedClipIds = expandToLinkGroup(ids)
        selectedGap = nil
        selectedTimelineRange = nil
    }

    private func forwardSelectionAnchorId() -> String? {
        timeline.tracks.enumerated()
            .flatMap { trackIndex, track in
                track.clips
                    .filter { selectedClipIds.contains($0.id) }
                    .map { (trackIndex: trackIndex, clip: $0) }
            }
            .sorted {
                if $0.clip.startFrame == $1.clip.startFrame {
                    return $0.trackIndex < $1.trackIndex
                }
                return $0.clip.startFrame < $1.clip.startFrame
            }
            .first?
            .clip
            .id
    }
}
