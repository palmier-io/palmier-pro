import SwiftUI

struct InspectorRotationField: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private var clipIds: [String] { clips.map(\.id) }

    var body: some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.rotationAt(frame: editor.activeFrame) },
            range: -3600...3600,
            displayMultiplier: 1,
            format: "%.0f",
            valueSuffix: "°",
            fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
            dragValueAdjustment: RotationSnap.adjusted,
            onDraggingValue: { rotation in
                editor.rotationSnapGuidesVisible = RotationSnap.isAxisAligned(rotation)
            },
            onChanged: { newValue in
                editor.applyRotation(clipIds: clipIds, valueDeg: newValue)
            }
        ) { newValue in
            editor.rotationSnapGuidesVisible = false
            editor.commitRotation(clipIds: clipIds, valueDeg: newValue)
        }
        .onDisappear {
            editor.rotationSnapGuidesVisible = false
        }
    }
}

enum RotationSnap {
    static let intervalDegrees = 90.0
    static let toleranceDegrees = 4.0

    static func adjusted(_ rotation: Double) -> Double {
        guard rotation.isFinite else { return rotation }
        let nearestAxis = (rotation / intervalDegrees).rounded() * intervalDegrees
        guard abs(rotation - nearestAxis) <= toleranceDegrees else { return rotation }
        return nearestAxis == 0 ? 0 : nearestAxis
    }

    static func isAxisAligned(_ rotation: Double) -> Bool {
        guard rotation.isFinite else { return false }
        return rotation.truncatingRemainder(dividingBy: intervalDegrees) == 0
    }
}
