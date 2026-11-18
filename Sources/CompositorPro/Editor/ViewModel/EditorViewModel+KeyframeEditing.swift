import Foundation

extension EditorViewModel {
    /// True when any selected clip holds a keyframe for any property at `frame`.
    func selectionHasKeyframe(at frame: Int) -> Bool {
        selectedClipIds.contains { clipId in
            guard let clip = clipFor(id: clipId) else { return false }
            return AnimatableProperty.allCases.contains { clip.keyframeFrames(for: $0).contains(frame) }
        }
    }

    /// Moves every keyframe at `frame` on the selected clips by `deltaFrames` in one undo action.
    @discardableResult
    func nudgeSelectedKeyframes(at frame: Int, by deltaFrames: Int) -> Bool {
        guard deltaFrames != 0 else { return false }
        var moved = false
        undo.perform(deltaFrames > 0 ? "Move Keyframes Later" : "Move Keyframes Earlier") {
            commitClipProperties(clipIds: Array(selectedClipIds), actionName: "Move Keyframes") { clip in
                guard frame >= clip.startFrame, frame <= clip.endFrame else { return }
                let target = min(clip.endFrame, max(clip.startFrame, frame + deltaFrames))
                guard target != frame else { return }
                for property in AnimatableProperty.allCases
                where clip.keyframeFrames(for: property).contains(frame) {
                    clip.moveKeyframe(for: property, from: frame, to: target)
                    moved = true
                }
            }
        }
        return moved
    }

    /// Removes keyframes at `frame` on the selected clips in one undo action.
    @discardableResult
    func removeSelectedKeyframes(at frame: Int) -> Bool {
        var removed = false
        undo.perform("Remove Keyframes") {
            commitClipProperties(clipIds: Array(selectedClipIds), actionName: "Remove Keyframes") { clip in
                for property in AnimatableProperty.allCases
                where clip.keyframeFrames(for: property).contains(frame) {
                    clip.removeKeyframe(for: property, at: frame)
                    removed = true
                }
            }
        }
        return removed
    }
}
