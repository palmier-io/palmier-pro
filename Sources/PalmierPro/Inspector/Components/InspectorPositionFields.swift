import SwiftUI

struct InspectorPositionFields: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)
        let frame = editor.currentFrame
        let xShared = sharedClipValue(clips) { $0.topLeftAt(frame: frame).x }
        let yShared = sharedClipValue(clips) { $0.topLeftAt(frame: frame).y }

        HStack(spacing: 4) {
            ScrubbableNumberField(
                value: xShared,
                range: -10...10,
                displayMultiplier: canvasW,
                format: "%.0f",
                fieldWidth: 36,
                trailingLabel: "X",
                onChanged: { newX in apply(setX: newX, setY: nil) }
            ) { newX in commit(setX: newX, setY: nil) }

            ScrubbableNumberField(
                value: yShared,
                range: -10...10,
                displayMultiplier: canvasH,
                format: "%.0f",
                fieldWidth: 36,
                trailingLabel: "Y",
                onChanged: { newY in apply(setX: nil, setY: newY) }
            ) { newY in commit(setX: nil, setY: newY) }
        }
        .fixedSize()
    }

    private func apply(setX: Double?, setY: Double?) {
        for c in clips { editor.applyPosition(clipId: c.id, setX: setX, setY: setY) }
    }

    private func commit(setX: Double?, setY: Double?) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips { editor.commitPosition(clipId: c.id, setX: setX, setY: setY) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Change Position")
    }
}
