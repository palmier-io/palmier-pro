import Foundation

/// A proposed new start frame for a single clip, produced by the ripple engine
/// and applied by the caller.
struct ClipShift: Equatable, Sendable {
    let clipId: String
    let newStartFrame: Int
}

/// A half-open `[start, end)` frame interval on a single track. Used to describe
/// the gaps that a ripple edit needs to close.
struct FrameRange: Equatable, Sendable {
    let start: Int
    let end: Int
    var length: Int { end - start }
}

/// Pure functions for ripple editing: computing how clips shift after
/// insertions or deletions.
enum RippleEngine {

    /// After removing clips from a track, compute new start frames for
    /// remaining clips that should shift backward to close the gap.
    static func computeRippleShifts(clips: [Clip], removedIds: Set<String>) -> [ClipShift] {
        let removedRanges = clips
            .filter { removedIds.contains($0.id) }
            .map { FrameRange(start: $0.startFrame, end: $0.endFrame) }
        return computeRippleShiftsForRanges(
            clips: clips.filter { !removedIds.contains($0.id) },
            removedRanges: removedRanges
        )
    }

    /// Shift clips leftward to close the gaps defined by `removedRanges`.
    /// Used when ranges come from a different track (sync-locked ripple).
    static func computeRippleShiftsForRanges(clips: [Clip], removedRanges: [FrameRange]) -> [ClipShift] {
        let merged = mergeRanges(removedRanges)
        guard !merged.isEmpty else { return [] }

        var shifts: [ClipShift] = []
        for clip in clips.sorted(by: { $0.startFrame < $1.startFrame }) {
            let shift = merged
                .filter { $0.end <= clip.startFrame }
                .reduce(0) { $0 + $1.length }
            if shift > 0 {
                shifts.append(ClipShift(clipId: clip.id, newStartFrame: clip.startFrame - shift))
            }
        }
        return shifts
    }

    /// Push all clips at or after `insertFrame` forward by `pushAmount` frames.
    static func computeRipplePush(
        clips: [Clip],
        insertFrame: Int,
        pushAmount: Int,
        excludeIds: Set<String> = []
    ) -> [ClipShift] {
        clips
            .filter { !excludeIds.contains($0.id) && $0.startFrame >= insertFrame }
            .map { ClipShift(clipId: $0.id, newStartFrame: $0.startFrame + pushAmount) }
    }

    // MARK: - Helpers

    private static func mergeRanges(_ ranges: [FrameRange]) -> [FrameRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [FrameRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = FrameRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
