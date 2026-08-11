import SwiftUI

struct InspectorPositionFields: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)
        let frame = editor.activeFrame
        let xShared = sharedClipValue(clips) { $0.topLeftAt(frame: frame).x }
        let yShared = sharedClipValue(clips) { $0.topLeftAt(frame: frame).y }

        HStack(spacing: AppTheme.Spacing.sm) {
            ScrubbableNumberField(
                value: xShared,
                range: -10...10,
                displayMultiplier: canvasW,
                format: "%.0f",
                fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
                trailingLabel: "X",
                onChanged: { newX in apply(setX: newX, setY: nil) }
            ) { newX in commit(setX: newX, setY: nil) }

            ScrubbableNumberField(
                value: yShared,
                range: -10...10,
                displayMultiplier: canvasH,
                format: "%.0f",
                fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
                trailingLabel: "Y",
                onChanged: { newY in apply(setX: nil, setY: newY) }
            ) { newY in commit(setX: nil, setY: newY) }
        }
        .fixedSize()
    }

    private func apply(setX: Double?, setY: Double?) {
        editor.applyPositions(clipIds: clips.map(\.id), setX: setX, setY: setY)
    }

    private func commit(setX: Double?, setY: Double?) {
        editor.commitPositions(clipIds: clips.map(\.id), setX: setX, setY: setY)
    }
}
