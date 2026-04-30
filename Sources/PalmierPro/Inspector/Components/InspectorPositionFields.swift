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
            ScrubbableNumberField(
                value: xShared,
                range: -10...10,
                displayMultiplier: canvasW,
                format: "%.0f",
                fieldWidth: 44,
                trailingLabel: "X",
                onChanged: { newX in apply(setX: newX, setY: nil) }
            ) { newX in commit(setX: newX, setY: nil) }

            ScrubbableNumberField(
                value: yShared,
                range: -10...10,
                displayMultiplier: canvasH,
                format: "%.0f",
                fieldWidth: 44,
                trailingLabel: "Y",
                onChanged: { newY in apply(setX: nil, setY: newY) }
            ) { newY in commit(setX: nil, setY: newY) }
        }
    }

    private func apply(setX: Double?, setY: Double?) {
        for c in clips {
            editor.applyClipProperty(clipId: c.id) { clip in
                clip.transform = makeTransform(from: clip.transform, setX: setX, setY: setY)
            }
        }
    }

    private func commit(setX: Double?, setY: Double?) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips {
            editor.commitClipProperty(clipId: c.id) { clip in
                clip.transform = makeTransform(from: clip.transform, setX: setX, setY: setY)
            }
        }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Change Position")
    }

    private func makeTransform(from t: Transform, setX: Double?, setY: Double?) -> Transform {
        let old = t.topLeft
        return Transform(
            topLeft: (setX ?? old.x, setY ?? old.y),
            width: t.width,
            height: t.height
        )
    }
}
