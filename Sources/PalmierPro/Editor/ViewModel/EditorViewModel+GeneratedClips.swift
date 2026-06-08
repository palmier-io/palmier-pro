import Foundation

extension EditorViewModel {
    struct TimelineSpan: Equatable, Sendable {
        var startFrame: Int
        var frameCount: Int
    }

    func selectedTimelineSpan() -> TimelineSpan? {
        if let range = validSelectedTimelineRange {
            let count = range.endFrame - range.startFrame
            guard count > 0 else { return nil }
            return TimelineSpan(startFrame: range.startFrame, frameCount: count)
        }
        let total = timeline.totalFrames
        guard total > 0 else { return nil }
        return TimelineSpan(startFrame: 0, frameCount: total)
    }

    @discardableResult
    func placeGeneratingAudioClip(
        placeholderId: String,
        startFrame: Int,
        spanSeconds: Double,
        actionName: String
    ) -> String? {
        guard let asset = mediaAssets.first(where: { $0.id == placeholderId }) else { return nil }
        let durationFrames = max(1, secondsToFrame(seconds: spanSeconds, fps: timeline.fps))

        let before = timeline
        undoManager?.disableUndoRegistration()
        let trackIdx = resolveOrCreateAudioTrack(startFrame: startFrame, duration: durationFrames)
        let ids = placeClip(
            asset: asset,
            trackIndex: trackIdx,
            startFrame: startFrame,
            durationFrames: durationFrames,
            addLinkedAudio: false
        )
        undoManager?.enableUndoRegistration()
        guard let clipId = ids.first else {
            timeline = before
            return nil
        }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
        notifyTimelineChanged()
        return clipId
    }

    func finalizeGeneratingClip(placeholderId: String, asset: MediaAsset) {
        guard let loc = findClipLocationByMediaRef(placeholderId) else { return }
        let realFrames = max(1, secondsToFrame(seconds: asset.duration, fps: timeline.fps))
        undoManager?.disableUndoRegistration()
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames = realFrames
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimStartFrame = 0
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimEndFrame = 0
        undoManager?.enableUndoRegistration()
        notifyTimelineChanged()
    }

    private func findClipLocationByMediaRef(_ mediaRef: String) -> ClipLocation? {
        for ti in timeline.tracks.indices {
            if let ci = timeline.tracks[ti].clips.firstIndex(where: { $0.mediaRef == mediaRef }) {
                return ClipLocation(trackIndex: ti, clipIndex: ci)
            }
        }
        return nil
    }
}
