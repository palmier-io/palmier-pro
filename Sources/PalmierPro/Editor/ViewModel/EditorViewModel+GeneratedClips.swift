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

    // Generation completes asynchronously — the placeholder may live on a background timeline.
    func finalizeGeneratingClip(placeholderId: String, asset: MediaAsset) {
        for i in timelines.indices {
            for ti in timelines[i].tracks.indices {
                guard let ci = timelines[i].tracks[ti].clips.firstIndex(where: { $0.mediaRef == placeholderId }) else { continue }
                let realFrames = max(1, secondsToFrame(seconds: asset.duration, fps: timelines[i].fps))
                undoManager?.disableUndoRegistration()
                timelines[i].tracks[ti].clips[ci].durationFrames = realFrames
                timelines[i].tracks[ti].clips[ci].trimStartFrame = 0
                timelines[i].tracks[ti].clips[ci].trimEndFrame = 0
                undoManager?.enableUndoRegistration()
                if timelines[i].id == activeTimelineId { notifyTimelineChanged() }
                return
            }
        }
    }
}
