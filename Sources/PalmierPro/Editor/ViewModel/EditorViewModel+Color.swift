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
}
