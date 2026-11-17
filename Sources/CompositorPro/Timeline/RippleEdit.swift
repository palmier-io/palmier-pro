import Foundation

/// Diff-based ripple: compare occupied frame intervals per track before and after an edit and emit
/// explicit adjustments, so ripple is independent of the command that triggered it.
enum RippleEdit {
    struct TrackSnapshot: Sendable, Equatable {
        let trackId: String
        /// Non-overlapping, half-open frame ranges, sorted by start.
        let intervals: [Range<Int>]

        init?(trackId: String, intervals: [Range<Int>]) {
            let sorted = intervals.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
            var previousEnd: Int?
            for interval in sorted {
                if let previousEnd, interval.lowerBound < previousEnd { return nil }
                previousEnd = interval.upperBound
            }
            self.trackId = trackId
            self.intervals = sorted
        }
    }

    /// Vacated frames close with a negative delta; new frames open with a positive delta.
    struct Adjustment: Sendable, Equatable {
        let trackId: String
        let interval: Range<Int>
        let delta: Int
    }

    /// Deterministic adjustment list. Invalid snapshots yield no adjustments, so callers can fall
    /// back to the command's existing behavior instead of partially applying a ripple.
    static func adjustments(before: [TrackSnapshot], after: [TrackSnapshot]) -> [Adjustment] {
        let beforeByTrack = Dictionary(uniqueKeysWithValues: before.map { ($0.trackId, $0.intervals) })
        let afterByTrack = Dictionary(uniqueKeysWithValues: after.map { ($0.trackId, $0.intervals) })
        var out: [Adjustment] = []

        for trackId in Set(beforeByTrack.keys).union(afterByTrack.keys) {
            let old = beforeByTrack[trackId] ?? []
            let new = afterByTrack[trackId] ?? []
            for interval in difference(old, new) {
                out.append(Adjustment(trackId: trackId, interval: interval, delta: -interval.count))
            }
            for interval in difference(new, old) {
                out.append(Adjustment(trackId: trackId, interval: interval, delta: interval.count))
            }
        }
        return out.sorted {
            ($0.trackId, $0.interval.lowerBound, $0.delta) < ($1.trackId, $1.interval.lowerBound, $1.delta)
        }
    }

    /// Applies gap-closing (negative) adjustments in one pass: intervals starting at or after the
    /// vacated range shift by the delta, clamped at zero. Positive deltas are left to insertion.
    static func applying(_ adjustments: [Adjustment], to snapshots: [TrackSnapshot]) -> [TrackSnapshot]? {
        var result: [TrackSnapshot] = []
        for snapshot in snapshots {
            var moved = snapshot.intervals
            for adjustment in adjustments where adjustment.trackId == snapshot.trackId && adjustment.delta < 0 {
                moved = moved.map { interval in
                    guard interval.lowerBound >= adjustment.interval.lowerBound else { return interval }
                    let lower = max(0, interval.lowerBound + adjustment.delta)
                    let upper = max(lower, interval.upperBound + adjustment.delta)
                    return lower..<upper
                }
            }
            guard let validated = TrackSnapshot(trackId: snapshot.trackId, intervals: moved) else { return nil }
            result.append(validated)
        }
        return result
    }

    /// Intervals in `lhs` not covered by any interval in `rhs`, as maximal ranges.
    private static func difference(_ lhs: [Range<Int>], _ rhs: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for interval in lhs {
            var remaining: [Range<Int>] = [interval]
            for covered in rhs where covered.overlaps(interval) {
                remaining = remaining.flatMap { piece in
                    guard piece.overlaps(covered) else { return [piece] }
                    var pieces: [Range<Int>] = []
                    if piece.lowerBound < covered.lowerBound {
                        pieces.append(piece.lowerBound..<min(piece.upperBound, covered.lowerBound))
                    }
                    if piece.upperBound > covered.upperBound {
                        pieces.append(max(piece.lowerBound, covered.upperBound)..<piece.upperBound)
                    }
                    return pieces.filter { !$0.isEmpty }
                }
            }
            out.append(contentsOf: remaining)
        }
        return out
    }
}
