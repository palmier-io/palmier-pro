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

    // Patch all timelines with placeholders for this asset.
    func finalizeGeneratingClip(placeholderId: String, asset: MediaAsset) {
        var touched: Set<String> = []
        undoManager?.disableUndoRegistration()
        for i in timelines.indices {
            let realFrames = max(1, secondsToFrame(seconds: asset.duration, fps: timelines[i].fps))
            for ti in timelines[i].tracks.indices {
                for ci in timelines[i].tracks[ti].clips.indices
                where timelines[i].tracks[ti].clips[ci].mediaRef == placeholderId {
                    timelines[i].tracks[ti].clips[ci].durationFrames = realFrames
                    timelines[i].tracks[ti].clips[ci].trimStartFrame = 0
                    timelines[i].tracks[ti].clips[ci].trimEndFrame = 0
                    touched.insert(timelines[i].id)
                }
            }
        }
        undoManager?.enableUndoRegistration()
        guard !touched.isEmpty else { return }
        // Rebuild when a touched timeline is visible from the active one, including through nests.
        if touched.contains(activeTimelineId)
            || timeline.reachableTimelines(resolve: timeline(for:)).contains(where: { touched.contains($0.id) }) {
            notifyTimelineChanged()
        }
    }
}
