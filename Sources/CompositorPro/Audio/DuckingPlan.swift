import Foundation

/// Volume envelope for an audio bed playing under dialogue, computed from speech spans.
///
/// Pure: no audio decoding, no model inference, no timeline access. The caller supplies speech
/// spans in absolute timeline frames and receives the keyframes to write, so the same
/// arithmetic backs preview, agent application, and tests.
struct DuckingPlan: Sendable, Equatable {
    struct Parameters: Sendable, Equatable {
        /// Negative gain applied while speech is present.
        var duckDb: Double = -12
        /// Frames from speech onset to full duck.
        var attackFrames: Int = 6
        /// Extra frames the bed stays ducked after speech ends.
        var holdFrames: Int = 6
        /// Frames from speech offset back to bed level.
        var releaseFrames: Int = 18
        /// Speech closer together than this becomes one span, so a pause between words
        /// does not pump the bed.
        var mergeGapFrames: Int = 12

        static let `default` = Parameters()
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyClip
        case nonFiniteDecibels(Double)
        case negativeFrames(String)

        var description: String {
            switch self {
            case .emptyClip: "The bed clip has no duration."
            case .nonFiniteDecibels(let db): "duckDb must be a finite number (got \(db))."
            case .negativeFrames(let field): "\(field) must be >= 0."
            }
        }
    }

    /// Half-open [start, end) in absolute timeline frames: where the bed sits below its own level.
    var windows: [Range<Int>]
    /// Volume keyframes in clip-relative frames. Values are linear gain, 1.0 = untouched.
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
        guard parameters.duckDb.isFinite else { throw Failure.nonFiniteDecibels(parameters.duckDb) }
        guard parameters.attackFrames >= 0, parameters.holdFrames >= 0,
              parameters.releaseFrames >= 0, parameters.mergeGapFrames >= 0 else {
            throw Failure.negativeFrames("attackFrames, holdFrames, releaseFrames and mergeGapFrames")
        }

        let bedStart = bedStartFrame
        let bedEnd = bedStartFrame + bedDurationFrames
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

        let duck = pow(10, parameters.duckDb / 20)
        let speechPlateaus = merge(clipped, joiningGapsShorterThan: parameters.mergeGapFrames)
        let windows = mergeRamps(
            speechPlateaus.map { plateau in
                Window(
                    ramp: max(bedStart, plateau.lowerBound - parameters.attackFrames)
                        ..< min(bedEnd, plateau.upperBound + parameters.releaseFrames),
                    speech: plateau
                )
            }
        )

        var track = KeyframeTrack<Double>()
        for window in windows {
            let duckIn = min(window.ramp.upperBound, window.speech.lowerBound + parameters.holdFrames)
            let duckOut = max(duckIn, min(window.ramp.upperBound, window.speech.upperBound))
            add(1.0, at: window.ramp.lowerBound - bedStart, to: &track, interpolation: .smooth)
            add(duck, at: duckIn - bedStart, to: &track, interpolation: .hold)
            add(duck, at: duckOut - bedStart, to: &track, interpolation: .smooth)
            add(1.0, at: window.ramp.upperBound - bedStart, to: &track, interpolation: .smooth)
        }
        // A clip-relative frame at durationFrames is past the last sample; the clip normalizer
        // would clamp it, so drop the trailing bed-level restore instead of letting it surprise.
        track.keyframes.removeAll { $0.frame >= bedDurationFrames && $0.value == 1.0 }

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
