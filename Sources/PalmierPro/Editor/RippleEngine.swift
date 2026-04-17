import Foundation

/// Pure functions for ripple editing: computing how clips shift after
/// insertions or deletions. No state, easily testable.
enum RippleEngine {

    /// After removing clips from a track, compute new start frames for
    /// remaining clips that should shift backward to close the gap.
    ///
    /// Returns [(clipId, newStartFrame)] for clips that need to move.
    static func computeRippleShifts(
        clips: [Clip],
        removedIds: Set<String>
    ) -> [(clipId: String, newStartFrame: Int)] {
        let removedRanges = clips
            .filter { removedIds.contains($0.id) }
            .map { (start: $0.startFrame, end: $0.endFrame) }
        return computeRippleShiftsForRanges(
            clips: clips.filter { !removedIds.contains($0.id) },
            removedRanges: removedRanges
        )
    }

    /// Shift clips leftward to close the gaps defined by `removedRanges`.
    /// Used when ranges come from a different track (sync-locked ripple).
    static func computeRippleShiftsForRanges(
        clips: [Clip],
        removedRanges: [(start: Int, end: Int)]
    ) -> [(clipId: String, newStartFrame: Int)] {
        let merged = mergeRanges(removedRanges)
        guard !merged.isEmpty else { return [] }

        var shifts: [(clipId: String, newStartFrame: Int)] = []
        for clip in clips.sorted(by: { $0.startFrame < $1.startFrame }) {
            var shift = 0
            for range in merged where range.end <= clip.startFrame {
                shift += range.end - range.start
            }
            if shift > 0 {
                shifts.append((clip.id, clip.startFrame - shift))
            }
        }
        return shifts
    }

    /// Push all clips at or after `insertFrame` forward by `pushAmount` frames.
    /// Returns [(clipId, newStartFrame)] for clips that need to move.
    static func computeRipplePush(
        clips: [Clip],
        insertFrame: Int,
        pushAmount: Int,
        excludeIds: Set<String> = []
    ) -> [(clipId: String, newStartFrame: Int)] {
        var shifts: [(clipId: String, newStartFrame: Int)] = []
        for clip in clips where !excludeIds.contains(clip.id) {
            if clip.startFrame >= insertFrame {
                shifts.append((clip.id, clip.startFrame + pushAmount))
            }
        }
        return shifts
    }

    // MARK: - Helpers

    private static func mergeRanges(_ ranges: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = (last.start, max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
