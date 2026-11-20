import Foundation

enum FreezeFrameError: Error, Equatable, CustomStringConvertible {
    case unknownClip(String)
    case notVisual(String)
    case outOfRange(frame: Int, durationFrames: Int)
    case tooLong(frames: Int, maximum: Int)
    case notZero
    case nothingToFreeze(String)

    var description: String {
        switch self {
        case .unknownClip(let id): "Clip not found: \(id)."
        case .notVisual(let id): "Clip \(id) has no picture to freeze."
        case .outOfRange(let frame, let duration):
            "Frame \(frame) is outside the clip's 0…\(max(0, duration - 1)) range."
        case .tooLong(let frames, let maximum):
            "A hold of \(frames) frames leaves no picture to play. At most \(maximum) frames can "
                + "be held before the clip's own start, or the freeze becomes the whole clip."
        case .notZero: "No freeze on this clip to change."
        case .nothingToFreeze(let id):
            "Clip \(id) is already at its first source frame, so there is nothing to hold."
        }
    }
}

extension EditorViewModel {
    struct FreezeReceipt: Sendable, Equatable {
        var clipId: String
        /// Clip-relative frame that is held.
        var frozenFrame: Int
        var freezeFrames: Int
        var freezeStartFrame: Int
        var freezeEndFrame: Int
        /// Timeline frame the picture resumes at.
        var resumeFrame: Int
        var sourceFramesConsumed: Int
        var audioKeepsPlaying: Bool
    }

    /// Holds the clip's picture on one frame for `frames`, as one undo step.
    ///
    /// Audio is untouched, so the hold lands on top of whatever is being said — which is the
    /// whole point of a freeze frame. This is a model capability, not a speed ramp: a ramp
    /// cannot reach zero and would need unbounded source to approach it.
    @discardableResult
    func freezeFrame(clipId: String, atFrame offset: Int, frames: Int) throws -> FreezeReceipt {
        guard frames >= 1 else { throw FreezeFrameError.notZero }
        guard let location = findClip(id: clipId) else { throw FreezeFrameError.unknownClip(clipId) }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard clip.mediaType.isVisual else { throw FreezeFrameError.notVisual(clipId) }
        guard offset >= 0, offset < clip.durationFrames else {
            throw FreezeFrameError.outOfRange(frame: offset, durationFrames: clip.durationFrames)
        }
        // The hold starts at the clip's head; the chosen frame is pulled into it.
        let playable = max(1, offset)
        guard frames < playable else {
            throw FreezeFrameError.tooLong(frames: frames, maximum: playable - 1)
        }
        let headSource = clip.timeMap.sourceOffset(atTimelineOffset: offset)
        let totalSource = clip.timeMap.sourceFramesConsumed
        let heldSource = Int(headSource.rounded())
        guard heldSource < totalSource else { throw FreezeFrameError.nothingToFreeze(clipId) }

        withTimelineSwap(actionName: "Freeze Frame") {
            var updated = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            // A hold consumes no source, so the source span is unchanged and only the timeline
            // length grows: the tail lands `frames` later and the audio is untouched.
            updated.durationFrames = clip.durationFrames + frames
            updated.freezeFrames = frames
            updated.clampFreezeToDuration()
            updated.clampKeyframesToDuration()
            updated.clampFadesToDuration()
            timeline.tracks[location.trackIndex].clips[location.clipIndex] = updated
        }
        onProjectCheckpointRequired?()
        let placed = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        return FreezeReceipt(
            clipId: clipId,
            frozenFrame: offset,
            freezeFrames: frames,
            freezeStartFrame: placed.startFrame,
            freezeEndFrame: placed.startFrame + frames,
            resumeFrame: placed.startFrame + frames,
            sourceFramesConsumed: placed.sourceFramesConsumed,
            audioKeepsPlaying: true
        )
    }

    /// Removes a freeze, restoring the clip's length. One undo step.
    @discardableResult
    func clearFreeze(clipId: String) throws -> FreezeReceipt {
        guard let location = findClip(id: clipId) else { throw FreezeFrameError.unknownClip(clipId) }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        let held = clip.freezeFrames
        guard held > 0 else { throw FreezeFrameError.notZero }
        withTimelineSwap(actionName: "Clear Freeze") {
            var updated = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            updated.durationFrames = max(1, updated.durationFrames - held)
            updated.freezeFrames = 0
            updated.clampFreezeToDuration()
            updated.clampKeyframesToDuration()
            updated.clampFadesToDuration()
            timeline.tracks[location.trackIndex].clips[location.clipIndex] = updated
        }
        onProjectCheckpointRequired?()
        let placed = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        return FreezeReceipt(
            clipId: clipId, frozenFrame: 0, freezeFrames: 0,
            freezeStartFrame: placed.startFrame, freezeEndFrame: placed.startFrame,
            resumeFrame: placed.startFrame, sourceFramesConsumed: placed.sourceFramesConsumed,
            audioKeepsPlaying: true
        )
    }
}
