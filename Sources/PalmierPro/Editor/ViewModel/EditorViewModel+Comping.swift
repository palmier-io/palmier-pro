import Foundation

/// Ableton-style comping: assemble chosen takes over a selected range onto a dedicated top Comp track.
extension EditorViewModel {

    /// True when a comp can run: a valid ruler range and a selected clip on a video take (non-comp) track.
    var canCompSelection: Bool {
        validSelectedTimelineRange != nil && compSourceTrackIndex != nil
    }

    /// Assemble the selected take's footage for the selected range onto the top Comp track.
    /// Non-destructive: the source takes are left untouched.
    func compSelectedRangeFromSelectedTake() {
        guard let range = validSelectedTimelineRange else {
            refuseWithToast("Select a range on the ruler first — Shift-drag across the time strip.")
            return
        }
        guard let sourceTrackIndex = compSourceTrackIndex else {
            refuseWithToast("Click a take clip to choose the take, then comp the range.")
            return
        }
        let window = range.startFrame..<range.endFrame
        let segments = timeline.tracks[sourceTrackIndex].clips
            .compactMap { Self.compSegment(of: $0, in: window) }
        guard !segments.isEmpty else {
            refuseWithToast("That take has no footage in the selected range.")
            return
        }
        withTimelineSwap(actionName: "Comp Take") {
            let compIndex = ensureCompTrackIndex()
            clearRegion(trackIndex: compIndex, start: window.lowerBound, end: window.upperBound, prune: false)
            timeline.tracks[compIndex].clips.append(contentsOf: segments)
            sortClips(trackIndex: compIndex)
        }
    }

    /// The take to comp from: the topmost non-comp video track holding a selected clip.
    private var compSourceTrackIndex: Int? {
        guard !selectedClipIds.isEmpty else { return nil }
        for (i, track) in timeline.tracks.enumerated() {
            guard track.type != .audio, !track.isComp else { continue }
            if track.clips.contains(where: { selectedClipIds.contains($0.id) }) { return i }
        }
        return nil
    }

    /// Find or create the topmost Comp track. Must be called inside a mutation.
    private func ensureCompTrackIndex() -> Int {
        if let existing = timeline.tracks.firstIndex(where: { $0.isComp }) { return existing }
        var track = Track(type: .video)
        track.isComp = true
        timeline.tracks.insert(track, at: 0)
        return 0
    }

    /// A standalone copy of `clip` clipped to `window`, retrimmed and rebased so it plays the same footage.
    nonisolated static func compSegment(of clip: Clip, in window: Range<Int>) -> Clip? {
        guard clip.mediaType != .text else { return nil }
        let start = max(clip.startFrame, window.lowerBound)
        let end = min(clip.endFrame, window.upperBound)
        guard end > start else { return nil }

        var c = clip
        let headCut = start - clip.startFrame
        if headCut > 0 {
            c.trimStartFrame += Int((Double(headCut) * clip.speed).rounded())
            c.fadeInFrames = 0
            c.opacityTrack = c.opacityTrack?.rebased(by: headCut, fallback: clip.opacity)
            c.volumeTrack = c.volumeTrack?.rebased(by: headCut, fallback: 0)
            c.positionTrack = c.positionTrack?.rebased(by: headCut, fallback: AnimPair(a: 0, b: 0))
            c.scaleTrack = c.scaleTrack?.rebased(by: headCut, fallback: AnimPair(a: 1, b: 1))
            c.rotationTrack = c.rotationTrack?.rebased(by: headCut, fallback: 0)
            c.cropTrack = c.cropTrack?.rebased(by: headCut, fallback: clip.crop)
        }
        if end < clip.endFrame { c.fadeOutFrames = 0 }
        c.startFrame = start
        c.durationFrames = end - start
        c.id = UUID().uuidString
        c.linkGroupId = nil
        c.captionGroupId = nil
        c.multicamGroupId = nil
        c.clampFadesToDuration()
        c.clampKeyframesToDuration()
        return c
    }
}
