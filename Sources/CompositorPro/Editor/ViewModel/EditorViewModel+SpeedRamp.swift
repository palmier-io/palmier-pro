import Foundation

enum SpeedRampError: Error, Equatable, CustomStringConvertible {
    case unknownClip(String)
    case notRetimable(String)
    case tooFewPoints(Int)
    case outOfOrder(point: Int)
    case outOfRange(frame: Int, durationFrames: Int)
    case nonFiniteSpeed(point: Int)
    case speedOutOfRange(point: Int, speed: Double)
    case tooShortToRamp(durationFrames: Int)
    case rampNotSupportable(neededSourceFrames: Int, availableSourceFrames: Int?)
    case hasVolumeAutomation

    var description: String {
        switch self {
        case .unknownClip(let id): "Clip not found: \(id)."
        case .notRetimable(let id):
            "Clip \(id) can't be retimed (nested timelines have no source to re-time)."
        case .tooFewPoints(let count): "A ramp needs at least 2 points (got \(count))."
        case .outOfOrder(let point):
            "Ramp point \(point) has a lower frame than the one before it. Frames must increase."
        case .outOfRange(let frame, let duration):
            "Ramp point at frame \(frame) is outside the clip's 0…\(duration) range."
        case .nonFiniteSpeed(let point): "Ramp point \(point) has a non-finite speed."
        case .speedOutOfRange(let point, let speed):
            "Ramp point \(point) speed \(speed) is outside "
                + "\(SourceTimeMap.minimumSpeed)…\(SourceTimeMap.maximumSpeed)."
        case .tooShortToRamp(let duration): "Clip is only \(duration) frames long; nothing to ramp."
        case .rampNotSupportable(let needed, let available):
            "That ramp needs \(needed) source frames but only "
                + "\(available.map(String.init) ?? "an unknown number of") are available. "
                + "Trim the clip or use a gentler ramp."
        case .hasVolumeAutomation:
            "Can't set a speed ramp with set_keyframes on the same call; apply them separately."
        }
    }
}

extension EditorViewModel {
    struct SpeedRampReceipt: Sendable, Equatable {
        var clipId: String
        var points: [SpeedRampPoint]
        var sourceFramesConsumed: Int
        var previousSpeed: Double
    }

    /// One authored ramp row, in the caller's own terms.
    struct SpeedRampPoint: Sendable, Equatable {
        var frame: Int
        var speed: Double
    }

    /// Applies a variable speed envelope to a clip as one undo step.
    ///
    /// The clip's timeline length is fixed; speed decides how much source it reads. Unlike a
    /// constant `speed`, a ramp does not rescale `durationFrames`, so everything downstream of
    /// the cut keeps its position.
    @discardableResult
    func applySpeedRamp(clipId: String, points: [SpeedRampPoint]) throws -> SpeedRampReceipt {
        guard let location = findClip(id: clipId) else { throw SpeedRampError.unknownClip(clipId) }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard clip.supportsRetiming else { throw SpeedRampError.notRetimable(clipId) }
        guard points.count >= 2 else { throw SpeedRampError.tooFewPoints(points.count) }
        guard clip.durationFrames > 1 else { throw SpeedRampError.tooShortToRamp(durationFrames: clip.durationFrames) }

        // The last samplable frame is durationFrames - 1. Validate and store against that, so the
        // receipt can never describe a ramp that differs from the one written to the clip.
        let lastSamplable = max(0, clip.durationFrames - 1)
        var normalized: [Keyframe<Double>] = []
        var previousFrame = -1
        for (index, point) in points.enumerated() {
            guard point.speed.isFinite else { throw SpeedRampError.nonFiniteSpeed(point: index) }
            guard point.frame >= 0, point.frame <= lastSamplable else {
                throw SpeedRampError.outOfRange(frame: point.frame, durationFrames: lastSamplable)
            }
            guard point.frame > previousFrame else { throw SpeedRampError.outOfOrder(point: index) }
            let clamped = SourceTimeMap.SpeedPoint.clamped(point.speed)
            guard clamped == point.speed else {
                throw SpeedRampError.speedOutOfRange(point: index, speed: point.speed)
            }
            previousFrame = point.frame
            normalized.append(Keyframe(frame: point.frame, value: point.speed, interpolationOut: .linear))
        }

        let track = KeyframeTrack(keyframes: normalized)
        // A ramp cannot invent source. Validate against the real media length, not the clip's
        // current span: a clip trimmed to half its asset has headroom a faster ramp can use.
        let consumed = SourceTimeMap(
            durationFrames: clip.durationFrames, speed: normalized[0].value, track: track
        ).sourceFramesConsumed
        guard consumed > 0 else {
            throw SpeedRampError.rampNotSupportable(
                neededSourceFrames: consumed,
                availableSourceFrames: mediaAssetLengthFrames(for: clip)
            )
        }
        if let available = mediaAssetLengthFrames(for: clip), clip.trimStartFrame + consumed > available {
            throw SpeedRampError.rampNotSupportable(
                neededSourceFrames: clip.trimStartFrame + consumed,
                availableSourceFrames: available
            )
        }

        let previousSpeed = clip.speed
        withTimelineSwap(actionName: "Speed Ramp") {
            var updated = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            updated.speed = points[0].speed
            updated.speedTrack = track
            updated.trimEndFrame = max(0, updated.trimEndFrame + updated.sourceFramesConsumed - consumed)
            updated.clampKeyframesToDuration()
            timeline.tracks[location.trackIndex].clips[location.clipIndex] = updated
        }
        onProjectCheckpointRequired?()
        return SpeedRampReceipt(
            clipId: clipId,
            points: normalized.map { SpeedRampPoint(frame: $0.frame, speed: $0.value) },
            sourceFramesConsumed: consumed,
            previousSpeed: previousSpeed
        )
    }

    /// Source frames the clip's media actually has, or nil when the length is unknown.
    private func mediaAssetLengthFrames(for clip: Clip) -> Int? {
        guard let asset = mediaAssetsById[clip.mediaRef], timeline.fps > 0 else { return nil }
        let frames = Int((asset.duration * Double(timeline.fps)).rounded())
        return frames > 0 ? frames : nil
    }

    /// Clears a ramp and returns the clip to one constant speed, as one undo step.
    @discardableResult
    func clearSpeedRamp(clipId: String, speed: Double = 1.0) throws -> SpeedRampReceipt {
        guard let location = findClip(id: clipId) else { throw SpeedRampError.unknownClip(clipId) }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard clip.supportsRetiming else { throw SpeedRampError.notRetimable(clipId) }
        guard clip.speedTrack?.isActive == true || clip.speed != speed else {
            throw SpeedRampError.tooFewPoints(0)
        }
        let clamped = SourceTimeMap.SpeedPoint.clamped(speed)
        // Hold the source the ramp was reading, so clearing a ramp never silently trims or
        // stretches the clip.
        let consumed = clip.timeMap.sourceFramesConsumed
        let newDuration = max(1, Int((Double(consumed) / clamped).rounded()))
        withTimelineSwap(actionName: "Clear Speed Ramp") {
            var updated = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            updated.speed = clamped
            updated.speedTrack = nil
            updated.setDuration(newDuration)
            updated.trimEndFrame = max(0, updated.trimEndFrame)
            timeline.tracks[location.trackIndex].clips[location.clipIndex] = updated
        }
        onProjectCheckpointRequired?()
        return SpeedRampReceipt(
            clipId: clipId,
            points: [SpeedRampPoint(frame: 0, speed: clamped)],
            sourceFramesConsumed: timeline.tracks[location.trackIndex]
                .clips[location.clipIndex].sourceFramesConsumed,
            previousSpeed: clip.speed
        )
    }
}
