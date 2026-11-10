import Foundation

/// Source↔timeline time conversion for a clip whose speed may change over its duration.
///
/// This is the only place speed is integrated. Every consumer — ripple deltas, slip and trim
/// bounds, sync drift, dead-air and gain-dip regions, captions, transcription, composition
/// time mapping, and both exporters — goes through here, so a clip with a constant `speed`
/// produces exactly the same numbers it always did and a ramp stays consistent everywhere.
///
/// Speed is a function of clip-relative timeline offset. Piecewise-linear keyframes make the
/// integral piecewise-quadratic, so both directions are closed-form and no sampling or search
/// is involved.
struct SourceTimeMap: Sendable, Equatable {
    /// Clip-relative timeline offset span the map covers.
    let durationFrames: Int
    /// Leading frames that hold one source frame instead of advancing. A freeze, not a rate.
    let frozenFrames: Int
    /// Speed at each clip-relative offset. Never empty; a constant-speed clip has one row.
    let profile: [SpeedPoint]
    /// Mean speed across the whole span, used where a single number is unavoidable.
    let averageSpeed: Double

    struct SpeedPoint: Sendable, Equatable {
        var offset: Int
        var speed: Double

        static func clamped(_ speed: Double) -> Double {
            guard speed.isFinite else { return 1 }
            return min(max(speed, SourceTimeMap.minimumSpeed), SourceTimeMap.maximumSpeed)
        }
    }

    /// Below this a clip would consume unbounded source for one frame of output.
    static let minimumSpeed: Double = 0.01
    /// Matches the ceiling the agent tool and the inspector field already enforce.
    static let maximumSpeed: Double = 1000

    /// Constant-speed map. `durationFrames * speed` consumed source, matching the historical scalar.
    init(durationFrames: Int, speed: Double, frozenFrames: Int = 0) {
        self.init(durationFrames: durationFrames, speed: speed, track: nil, frozenFrames: frozenFrames)
    }

    /// Piecewise-linear map from clip-relative speed keyframes. Unset track means constant `speed`.
    init(durationFrames: Int, speed: Double, track: KeyframeTrack<Double>?, frozenFrames: Int = 0) {
        let span = max(0, durationFrames)
        self.frozenFrames = min(max(0, frozenFrames), span)
        let constant = SpeedPoint.clamped(speed)
        guard let track, track.keyframes.count > 1 else {
            self.profile = [SpeedPoint(offset: 0, speed: constant)]
            self.durationFrames = span
            self.averageSpeed = constant
            return
        }
        // Offset 0 anchors the envelope so a track that starts later still covers the head.
        var rows: [SpeedPoint] = [SpeedPoint(offset: 0, speed: constant)]
        for keyframe in track.keyframes.sorted(by: { $0.frame < $1.frame }) {
            let value = SpeedPoint.clamped(keyframe.value)
            if keyframe.frame > span { continue }
            if let last = rows.last, last.offset == keyframe.frame {
                rows[rows.count - 1].speed = value
            } else if keyframe.frame > (rows.last?.offset ?? -1) {
                rows.append(SpeedPoint(offset: keyframe.frame, speed: value))
            }
        }
        self.profile = rows
        self.durationFrames = span
        self.averageSpeed = span > self.frozenFrames
            ? Self.integrate(rows, over: 0 ..< (span - self.frozenFrames)) / Double(span - self.frozenFrames)
            : constant
    }

    var isConstantSpeed: Bool {
        guard let first = profile.first else { return true }
        return profile.allSatisfy { $0.speed == first.speed }
    }

    /// Speed at a clip-relative timeline offset.
    func speed(atOffset offset: Int) -> Double {
        guard let first = profile.first else { return 1 }
        guard profile.count > 1 else { return first.speed }
        let clamped = max(0, offset)
        guard let next = profile.first(where: { $0.offset > clamped }) else {
            return profile[profile.count - 1].speed
        }
        let index = profile.firstIndex(of: next)!
        guard index > 0 else { return next.speed }
        let a = profile[index - 1]
        let t = Double(clamped - a.offset) / Double(next.offset - a.offset)
        return a.speed + (next.speed - a.speed) * min(max(t, 0), 1)
    }

    /// Source offset from trim start for a clip-relative timeline offset.
    ///
    /// A frozen lead consumes nothing, so every offset inside the hold maps to source frame 0.
    func sourceOffset(atTimelineOffset offset: Int) -> Double {
        let elapsed = max(0, offset - frozenFrames)
        guard elapsed > 0 else { return 0 }
        return Self.integrate(profile, over: 0 ..< elapsed)
    }

    /// Source offset from trim start for an absolute timeline frame.
    func sourceOffset(atTimelineFrame frame: Int, startFrame: Int) -> Double {
        sourceOffset(atTimelineOffset: frame - startFrame)
    }

    /// Source delta for a timeline delta, measured from offset 0 — the span's average rate,
    /// and exact for constant speed. Trim and slip edges use this direction.
    func sourceDelta(forTimelineDelta delta: Int) -> Int {
        if isConstantSpeed {
            return Int((Double(delta) * averageSpeed).rounded())
        }
        let magnitude = Int(sourceOffset(atTimelineOffset: frozenFrames + max(0, abs(delta))).rounded())
        return delta < 0 ? -magnitude : magnitude
    }

    /// Clip-relative timeline delta for a source delta. Negative and out-of-span values pass
    /// through unclamped, which is what trim and slip edges need. Never returns a delta longer
    /// than the span, because a speed change cannot stretch a clip.
    func timelineDelta(forSourceDelta source: Double) -> Int {
        let magnitude = timelineOffset(forSourceOffset: abs(source))
        let sign = source < 0 ? -1 : 1
        let capped = min(magnitude, max(0, durationFrames))
        return capped * sign
    }

    /// Clip-relative timeline offset for a source offset, with configurable rounding rule.
    func timelineOffset(
        forSourceOffset source: Double,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Int {
        guard durationFrames > 0, let first = profile.first else { return 0 }
        let span = durationFrames - frozenFrames
        guard span > 0 else { return 0 }
        // Source frame 0 is the end of the hold and the first playable frame. Reporting the
        // playable frame is the useful answer: it is where content actually starts.
        guard source > 0 else { return frozenFrames }
        let total = Self.integrate(profile, over: 0 ..< span)
        let target = min(max(source, 0), total)
        if profile.count == 1 {
            let offset = Int((target / max(first.speed, 1e-12)).rounded(rounding))
            return min(max(offset, 0), span) + frozenFrames
        }
        var consumed = 0.0
        for index in 0 ..< profile.count - 1 {
            let a = profile[index]
            let b = profile[index + 1]
            let segment = Self.integrate(profile, over: a.offset ..< b.offset)
            guard target <= consumed + segment else {
                consumed += segment
                continue
            }
            let within = Self.segmentOffset(a: a, b: b, source: target - consumed, rounding: rounding)
            return min(max(within, a.offset), span) + frozenFrames
        }
        return durationFrames
    }

    /// Source frames the visible portion consumes. Rounds exactly like the old scalar formula,
    /// so constant-speed clips are unchanged.
    var sourceFramesConsumed: Int {
        Int(sourceOffset(atTimelineOffset: durationFrames).rounded())
    }

    /// Piecewise segments the composition builder and exporters map one-for-one.
    ///
    /// Each segment is a constant-scale span, so `AVMutableComposition` can express it with a
    /// single `scaleTimeRange` and Premiere/FCPXML with a single time-map interval.
    struct Segment: Sendable, Equatable {
        /// Clip-relative timeline span, half-open.
        var timelineRange: Range<Int>
        /// Source frames consumed across the span.
        var sourceSpan: Double
        var speed: Double
    }

    var segments: [Segment] {
        guard durationFrames > 0, let first = profile.first else { return [] }
        let span = durationFrames - frozenFrames
        let hold: [Segment] = frozenFrames > 0
            // One source frame stretched across the hold: AVMutableComposition can express a
            // freeze by scaling a single-frame slice, and nothing else can hold a frame.
            ? [Segment(
                timelineRange: 0 ..< frozenFrames,
                sourceSpan: 1,
                speed: 1 / Double(frozenFrames)
            )]
            : []
        guard span > 0 else { return hold }
        guard profile.count > 1 else {
            return hold + [Segment(
                timelineRange: frozenFrames ..< durationFrames,
                sourceSpan: Double(span) * first.speed,
                speed: first.speed
            )]
        }
        var result: [Segment] = []
        for index in 0 ..< profile.count - 1 {
            let a = profile[index]
            let b = profile[index + 1]
            let start = frozenFrames + min(a.offset, span)
            let end = frozenFrames + min(b.offset, span)
            guard start < end else { continue }
            let sourceSpan = Self.integrate(profile, over: a.offset ..< b.offset)
            result.append(Segment(
                timelineRange: start ..< end,
                sourceSpan: sourceSpan,
                speed: sourceSpan / Double(end - start)
            ))
        }
        // A ramp that ends before the clip does still has to play out its tail.
        if let last = result.last, last.timelineRange.upperBound < durationFrames {
            let start = last.timelineRange.upperBound
            let sourceSpan = Self.integrate(profile, over: (start - frozenFrames) ..< span)
            result.append(Segment(
                timelineRange: start ..< durationFrames,
                sourceSpan: sourceSpan,
                speed: sourceSpan / Double(durationFrames - start)
            ))
        }
        return hold + result
    }

    // MARK: - Integration

    /// ∫ speed d(offset) across `range`, in source frames.
    static func integrate(_ profile: [SpeedPoint], over range: Range<Int>) -> Double {
        guard let first = profile.first, range.upperBound > range.lowerBound else { return 0 }
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        guard profile.count == 1 else {
            return piecewise(profile, from: lower, to: upper)
        }
        return Double(upper - lower) * first.speed
    }

    private static func piecewise(_ profile: [SpeedPoint], from lower: Int, to upper: Int) -> Double {
        var total = 0.0
        for index in 0 ..< max(0, profile.count - 1) {
            let a = profile[index]
            let b = profile[index + 1]
            let start = max(lower, a.offset)
            let end = min(upper, b.offset)
            guard start < end else { continue }
            total += trapezoid(a: a, b: b, from: start, to: end)
        }
        // Past the last keyframe the speed holds.
        let last = profile[profile.count - 1]
        if upper > last.offset {
            total += Double(upper - max(lower, last.offset)) * last.speed
        }
        return total
    }

    private static func trapezoid(a: SpeedPoint, b: SpeedPoint, from lower: Int, to upper: Int) -> Double {
        let span = Double(b.offset - a.offset)
        guard span > 0 else { return Double(upper - lower) * a.speed }
        let slope = (b.speed - a.speed) / span
        // Exact integral of a linear ramp, evaluated at both ends.
        func area(to offset: Int) -> Double {
            let t = Double(offset - a.offset)
            return a.speed * t + slope * t * t / 2
        }
        return area(to: upper) - area(to: lower)
    }

    /// Offset into the segment `a → b` at which `source` frames past `a` have been consumed.
    private static func segmentOffset(
        a: SpeedPoint, b: SpeedPoint, source: Double,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Int {
        let span = Double(b.offset - a.offset)
        guard span > 0 else {
            return a.offset + Int((source / max(a.speed, 1e-12)).rounded(rounding))
        }
        let slope = (b.speed - a.speed) / span
        // source = a.speed*x + slope/2 * x^2
        let x: Double
        if abs(slope) < 1e-12 {
            x = source / max(a.speed, 1e-12)
        } else {
            let discriminant = a.speed * a.speed + 2 * slope * source
            guard discriminant >= 0 else { return a.offset }
            x = (-a.speed + sqrt(discriminant)) / slope
        }
        return a.offset + Int(min(max(x, 0), span).rounded(rounding))
    }
}
