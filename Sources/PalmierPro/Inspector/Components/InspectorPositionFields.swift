import SwiftUI

struct InspectorPositionFields: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)
        let xShared = sharedClipValue(clips) { $0.transform.topLeft.x }
        let yShared = sharedClipValue(clips) { $0.transform.topLeft.y }

        HStack(spacing: AppTheme.Spacing.sm) {
            InspectorNumberField(label: "X", value: xShared.map { $0 * canvasW }) { newX in
                commitPosition(setX: newX / canvasW, setY: nil)
            }
            InspectorNumberField(label: "Y", value: yShared.map { $0 * canvasH }) { newY in
                commitPosition(setX: nil, setY: newY / canvasH)
            }
        }
    }

    private func commitPosition(setX: Double?, setY: Double?) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips {
            editor.commitClipProperty(clipId: c.id) { clip in
                let old = clip.transform.topLeft
                clip.transform = Transform(
                    topLeft: (setX ?? old.x, setY ?? old.y),
                    width: clip.transform.width,
                    height: clip.transform.height
                )
            }
        }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Change Position")
    }
}
