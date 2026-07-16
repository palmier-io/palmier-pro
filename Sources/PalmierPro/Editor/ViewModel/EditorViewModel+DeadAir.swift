import AppKit

/// Dead-air removal: maps SpeechMaskStore spans onto timeline ranges and ripple-deletes them.
extension EditorViewModel {

    private func deadAirMask(for clip: Clip) -> [Bool]? {
        guard let member = multicamGroup(of: clip)?.member(mediaRef: clip.mediaRef) else {
            return mediaVisualCache.deadAirMask(for: clip.mediaRef)
        }
        guard let groupMask = multicamDeadAirMask(for: clip) else { return nil }
        let shift = Int((member.sync.offsetSeconds / VoiceActivity.chunkDuration).rounded())
        if shift > 0 { return Array(groupMask.dropFirst(shift)) }
        if shift < 0 { return [Bool](repeating: false, count: -shift) + groupMask }
        return groupMask
    }

    /// The dead-air span under `timelineFrame` in `clip`, as a timeline range. Nil when the frame isn't dead air.
    func deadAirSpanRange(clip: Clip, atTimelineFrame frame: Int) -> FrameRange? {
        guard let mask = deadAirMask(for: clip), !mask.isEmpty else { return nil }
        let cellFrames = VoiceActivity.chunkDuration * Double(max(1, timeline.fps))
        let sourceFrame = Double(clip.trimStartFrame) + Double(frame - clip.startFrame) * clip.speed
        let cell = Int(sourceFrame / cellFrames)
        guard mask.indices.contains(cell), mask[cell] else { return nil }
        var lo = cell
        while lo > 0 && mask[lo - 1] { lo -= 1 }
        var hi = cell + 1
        while hi < mask.count && mask[hi] { hi += 1 }
        return timelineRange(clip: clip, sourceStart: Double(lo) * cellFrames, sourceEnd: Double(hi) * cellFrames)
    }

    /// Every dead-air span visible within `clip`, as timeline ranges.
    func deadAirRanges(for clip: Clip) -> [FrameRange] {
        guard let mask = deadAirMask(for: clip), !mask.isEmpty else { return [] }
        let cellFrames = VoiceActivity.chunkDuration * Double(max(1, timeline.fps))
        var ranges: [FrameRange] = []
        var i = 0
        while i < mask.count {
            guard mask[i] else { i += 1; continue }
            var j = i
            while j < mask.count && mask[j] { j += 1 }
            if let r = timelineRange(clip: clip, sourceStart: Double(i) * cellFrames, sourceEnd: Double(j) * cellFrames) {
                ranges.append(r)
            }
            i = j
        }
        return ranges
    }

    /// Dead-air ranges grouped by track; each track ripples its own spans.
    func allDeadAir() -> [(trackIndex: Int, ranges: [FrameRange])] {
        var out: [(Int, [FrameRange])] = []
        for (ti, track) in timeline.tracks.enumerated() where track.type == .audio {
            let ranges = track.clips.flatMap { deadAirRanges(for: $0) }
            if !ranges.isEmpty { out.append((ti, ranges)) }
        }
        return out
    }

    func removeDeadAir(clipId: String, atTimelineFrame frame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard let range = deadAirSpanRange(clip: clip, atTimelineFrame: frame) else { return }
        if case .refused(let reason) = rippleDeleteRangesOnTrack(trackIndex: loc.trackIndex, ranges: [range]) {
            NSSound.beep()
            Log.editor.notice("remove dead air blocked: \(reason)")
        }
    }

    /// Ripples dead air per-track, updating ranges between passes. Stops if a track refuses.
    @discardableResult
    func removeAllDeadAir() -> (sections: Int, removedFrames: Int, refusal: String?)? {
        undo.perform("Remove Dead Air") {
            var sections = 0
            var removedFrames = 0
            var refusal: String?
            for _ in timeline.tracks.indices {
                guard let next = allDeadAir().first else { break }
                switch rippleDeleteRangesOnTrack(trackIndex: next.trackIndex, ranges: next.ranges) {
                case .ok(let report):
                    sections += next.ranges.count
                    removedFrames += report.removedFrames
                case .refused(let reason):
                    refusal = reason
                    NSSound.beep()
                    Log.editor.notice("remove dead air blocked: \(reason)")
                }
                if refusal != nil { break }
            }
            guard sections > 0 || refusal != nil else { return nil }
            return (sections, removedFrames, refusal)
        }
    }

    private func timelineRange(clip: Clip, sourceStart: Double, sourceEnd: Double) -> FrameRange? {
        let s0 = max(sourceStart, Double(clip.trimStartFrame))
        let s1 = min(sourceEnd, Double(clip.trimStartFrame + clip.sourceFramesConsumed))
        guard s1 > s0, clip.speed > 0 else { return nil }
        let t0 = Double(clip.startFrame) + (s0 - Double(clip.trimStartFrame)) / clip.speed
        let t1 = Double(clip.startFrame) + (s1 - Double(clip.trimStartFrame)) / clip.speed
        let range = FrameRange(start: Int(t0.rounded()), end: Int(t1.rounded()))
        return range.length > 0 ? range : nil
    }
}
