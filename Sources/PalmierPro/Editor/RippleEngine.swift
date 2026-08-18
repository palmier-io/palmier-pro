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

/// A user-selected empty gap on a single track
struct GapSelection: Equatable, Sendable {
    let trackIndex: Int
    let range: FrameRange
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

    /// Close removed spans. One range list per shifting track; remap only tracks that still hold the marker.
    static func rippleMarkers(_ markers: [TimelineMarker], closing trackRanges: [[FrameRange]]) -> [TimelineMarker] {
        let mergedTracks = trackRanges.map { mergeRanges($0.filter { $0.length > 0 }) }.filter { !$0.isEmpty }
        guard !mergedTracks.isEmpty else { return markers }
        return markers.compactMap { marker in
            let surviving = mergedTracks.compactMap { ranges -> (start: Int, end: Int)? in
                let start = mapFrame(marker.startFrame, closing: ranges)
                if !marker.isRange {
                    let removed = ranges.contains { ($0.start..<$0.end).contains(marker.startFrame) }
                    return removed ? nil : (start, start)
                }
                let end = mapFrame(marker.endFrame, closing: ranges)
                return end > start ? (start, end) : nil
            }
            guard let first = surviving.first else { return nil }
            var next = marker
            next.startFrame = surviving.map(\.start).min() ?? first.start
            if marker.isRange {
                let newEnd = surviving.map(\.end).min() ?? first.end
                guard newEnd > next.startFrame else { return nil }
                next.durationFrames = newEnd - next.startFrame
            }
            return next
        }
    }

    /// Open a gap at `insertFrame`. Negative `pushAmount` closes `[insertFrame + pushAmount, insertFrame)`.
    static func rippleMarkers(
        _ markers: [TimelineMarker],
        openingAt insertFrame: Int,
        by pushAmount: Int
    ) -> [TimelineMarker] {
        guard pushAmount != 0 else { return markers }
        if pushAmount < 0 {
            return rippleMarkers(
                markers,
                closing: [[FrameRange(start: insertFrame + pushAmount, end: insertFrame)]]
            )
        }
        return markers.map { marker in
            var next = marker
            if next.startFrame >= insertFrame {
                next.startFrame += pushAmount
            } else if next.isRange, next.endFrame > insertFrame {
                next.durationFrames += pushAmount
            }
            return next
        }
    }

    // MARK: - Helpers

    private static func mapFrame(_ frame: Int, closing ranges: [FrameRange]) -> Int {
        var mapped = frame
        for range in ranges {
            if range.end <= frame {
                mapped -= range.length
            } else if range.start < frame {
                mapped -= frame - range.start
            }
        }
        return max(0, mapped)
    }

    static func mergeRanges(_ ranges: [FrameRange]) -> [FrameRange] {
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
