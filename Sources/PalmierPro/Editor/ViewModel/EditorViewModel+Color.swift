import Foundation

extension EditorViewModel {

    /// Set (or clear with `nil`) the chroma key on a clip. Undoable; triggers a
    /// preview rebuild so the custom compositor picks up the change.
    func setChromaKey(clipId: String, _ key: ChromaKey?) {
        mutateClips(ids: [clipId], actionName: "Chroma Key") { clip in
            clip.chromaKey = key
        }
    }

    /// Set (or clear with `nil`) the colour grade on an adjustment clip. Undoable.
    func setColorGrade(clipId: String, _ grade: ColorGrade?) {
        mutateClips(ids: [clipId], actionName: "Color Grade") { clip in
            clip.colorGrade = grade
        }
    }

    /// Create a topmost adjustment layer spanning the current timeline and select it.
    @discardableResult
    func addAdjustmentLayer() -> String {
        let span = max(1, timeline.totalFrames)
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: span)
        clip.mediaType = .adjustment
        clip.sourceClipType = .adjustment
        clip.colorGrade = ColorGrade()
        let clipId = clip.id
        let track = Track(type: .adjustment, clips: [clip])
        withTimelineSwap(actionName: "Add Adjustment Layer") {
            timeline.tracks.insert(track, at: 0)
        }
        selectedClipIds = [clipId]
        return clipId
    }
}
