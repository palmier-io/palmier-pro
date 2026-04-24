import SwiftUI

struct InspectorPositionFields: View {
    let clip: Clip
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let tl = clip.transform.topLeft
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)

        HStack(spacing: AppTheme.Spacing.sm) {
            InspectorNumberField(label: "X", value: tl.x * canvasW) { newX in
                editor.commitClipProperty(clipId: clip.id) {
                    let old = $0.transform.topLeft
                    $0.transform = Transform(topLeft: (newX / canvasW, old.y), width: $0.transform.width, height: $0.transform.height)
                }
            }
            InspectorNumberField(label: "Y", value: tl.y * canvasH) { newY in
                editor.commitClipProperty(clipId: clip.id) {
                    let old = $0.transform.topLeft
                    $0.transform = Transform(topLeft: (old.x, newY / canvasH), width: $0.transform.width, height: $0.transform.height)
                }
            }
        }
    }
}
