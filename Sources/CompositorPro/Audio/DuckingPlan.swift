import Foundation

struct DuckingPlan: Sendable, Equatable {
    struct Parameters: Codable, Sendable, Equatable {
        /// Negative gain applied while speech is present.
        var duckDb: Double = -12
        /// Lookahead frames before speech onset.
        var attackFrames: Int = 6
        /// Extra frames the bed stays ducked after speech ends.
        var holdFrames: Int = 6
        /// Recovery frames after the hold.
        var releaseFrames: Int = 18
        /// Speech closer together than this becomes one span, so a pause between words
        /// does not pump the bed.
        var mergeGapFrames: Int = 12

        static let `default` = Parameters()
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyClip
        case invalidBedRange
        case nonFiniteDecibels(Double)
        case positiveDecibels
        case excessiveAttenuation
        case negativeFrames(String)

        var description: String {
            switch self {
            case .emptyClip: "The bed clip has no duration."
            case .invalidBedRange: "The bed frame range is invalid or overflowing."
            case .nonFiniteDecibels(let db): "duckDb must be a finite number (got \(db))."
            case .positiveDecibels: "duckDb must be zero or negative."
            case .excessiveAttenuation: "duckDb must be at least -96 dB."
            case .negativeFrames(let field): "\(field) must be >= 0."
            }
        }
    }

    /// Half-open [start, end) in absolute timeline frames: where the bed sits below its own level.
    var windows: [Range<Int>]
    /// Clip-relative volume keyframes in dB, matching Clip.volumeTrack.
    var keyframes: [Keyframe<Double>]
    /// Speech spans dropped for falling outside the bed or being empty.
    var ignoredSpans: Int

    var isEmpty: Bool { keyframes.isEmpty }

    /// Duck window paired with the speech that produced it, so overlapping ramps merge
    /// instead of stacking a release and an attack inside each other.
    private struct Window {
        var ramp: Range<Int>
        var speech: Range<Int>
    }

    static func plan(
        bedStartFrame: Int,
        bedDurationFrames: Int,
        speechSpans: [Range<Int>],
        parameters: Parameters = .default
    ) throws -> DuckingPlan {
        guard bedDurationFrames > 0 else { throw Failure.emptyClip }
        let end = bedStartFrame.addingReportingOverflow(bedDurationFrames)
        guard bedStartFrame >= 0, !end.overflow else { throw Failure.invalidBedRange }
        guard parameters.duckDb.isFinite else { throw Failure.nonFiniteDecibels(parameters.duckDb) }
        guard parameters.duckDb <= 0 else { throw Failure.positiveDecibels }
        guard parameters.duckDb >= -96 else { throw Failure.excessiveAttenuation }
        guard parameters.attackFrames >= 0, parameters.holdFrames >= 0,
              parameters.releaseFrames >= 0, parameters.mergeGapFrames >= 0 else {
            throw Failure.negativeFrames("attackFrames, holdFrames, releaseFrames and mergeGapFrames")
        }

        let bedStart = bedStartFrame
        let bedEnd = end.partialValue
        var ignored = 0
        var clipped: [Range<Int>] = []
        for span in speechSpans {
            let lower = max(span.lowerBound, bedStart)
            let upper = min(span.upperBound, bedEnd)
            if lower < upper {
                clipped.append(lower ..< upper)
            } else {
                ignored += 1
            }
        }

        guard parameters.duckDb < 0 else {
            return DuckingPlan(windows: [], keyframes: [], ignoredSpans: ignored)
        }
        let speechPlateaus = merge(clipped, joiningGapsShorterThan: parameters.mergeGapFrames)
        let windows = mergeRamps(
            speechPlateaus.map { plateau in
                let holdEnd = plateau.upperBound + min(parameters.holdFrames, bedEnd - plateau.upperBound)
                return Window(
                    ramp: (plateau.lowerBound - min(parameters.attackFrames, plateau.lowerBound - bedStart))
                        ..< (holdEnd + min(parameters.releaseFrames, bedEnd - holdEnd)),
                    speech: plateau
                )
            }
        )

        var track = KeyframeTrack<Double>()
        // Bed level (0 dB) before the first attack, so the envelope starts at unity gain.
        // No speech means no envelope at all, not a single flat keyframe.
        if !windows.isEmpty { add(0, at: 0, to: &track, interpolation: .hold) }
        for window in windows {
            let duckOut = window.speech.upperBound + min(parameters.holdFrames, bedEnd - window.speech.upperBound)
            add(0, at: window.ramp.lowerBound - bedStart, to: &track, interpolation: .smooth)
            add(parameters.duckDb, at: window.speech.lowerBound - bedStart, to: &track, interpolation: .hold)
            if duckOut < bedEnd {
                add(parameters.duckDb, at: duckOut - bedStart, to: &track, interpolation: .smooth)
                add(0, at: min(window.ramp.upperBound - bedStart, bedDurationFrames - 1),
                    to: &track, interpolation: .hold)
            }
        }

        return DuckingPlan(
            windows: windows.map(\.ramp),
            keyframes: track.keyframes,
            ignoredSpans: ignored
        )
    }

    private static func add(
        _ value: Double,
        at frame: Int,
        to track: inout KeyframeTrack<Double>,
        interpolation: Interpolation
    ) {
        let clamped = max(0, frame)
        if let existing = track.keyframes.firstIndex(where: { $0.frame == clamped }) {
            track.keyframes[existing].value = value
            track.keyframes[existing].interpolationOut = interpolation
        } else {
            track.upsert(Keyframe(frame: clamped, value: value, interpolationOut: interpolation))
        }
    }

    private static func merge(
        _ spans: [Range<Int>],
        joiningGapsShorterThan gap: Int
    ) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard let last = result.last else {
                result.append(span)
                continue
            }
            if span.lowerBound - last.upperBound <= gap {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Union windows whose ramps overlap, keeping the widest speech range of each group so a
    /// merged window stays ducked across the whole group.
    private static func mergeRamps(_ windows: [Window]) -> [Window] {
        var result: [Window] = []
        for window in windows.sorted(by: { $0.ramp.lowerBound < $1.ramp.lowerBound }) {
            guard let last = result.last else {
                result.append(window)
                continue
            }
            if window.ramp.lowerBound < last.ramp.upperBound {
                result[result.count - 1].ramp = last.ramp.lowerBound ..< max(last.ramp.upperBound, window.ramp.upperBound)
                result[result.count - 1].speech = last.speech.lowerBound ..< max(last.speech.upperBound, window.speech.upperBound)
            } else {
                result.append(window)
            }
        }
        return result
    }
}

enum AudioFadeCurve {
    /// Gain multipliers for an audio crossfade of `frames` frames ending at the cut.
    ///
    /// Equal power holds perceived loudness through the overlap: the two gains stay on a quarter
    /// unit circle, so their squares sum to 1 at every point. A linear fade instead sums to 0.5
    /// mid-overlap, a 3 dB dip. `fadeInFrames`/`fadeOutFrames` can only express linear-ish ramps,
    /// so this curve is written as sampled volume keyframes instead.
    static func equalPowerSamples(frames: Int) -> [(frameOffset: Int, outgoing: Double, incoming: Double)] {
        guard frames > 0 else { return [] }
        let step = max(2, frames / 24)
        var samples: [(frameOffset: Int, outgoing: Double, incoming: Double)] = []
        var offset = 0
        while offset < frames {
            let phase = Double(offset) / Double(frames) * .pi / 2
            samples.append((frameOffset: offset, outgoing: cos(phase), incoming: sin(phase)))
            offset += step
        }
        samples.append((frameOffset: frames, outgoing: 0, incoming: 1))
        return samples
    }
}
