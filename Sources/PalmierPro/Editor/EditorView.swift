import SwiftUI

struct EditorView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        VSplitView {
            // Top: three-column layout
            HSplitView {
                MediaPanelView()
                    .frame(minWidth: Layout.mediaPanelMin, idealWidth: Layout.mediaPanelDefault, maxWidth: Layout.mediaPanelMax)

                panelDivider

                PreviewContainerView()
                    .frame(minWidth: Layout.previewMinWidth)

                panelDivider

                InspectorView()
                    .frame(minWidth: Layout.inspectorMin, idealWidth: Layout.inspectorDefault, maxWidth: Layout.inspectorMax)
            }

            // Bottom: toolbar + timeline spanning full width
            VStack(spacing: 0) {
                ToolbarView()
                    .frame(height: Layout.toolbarHeight)

                TimelineContainerView()
            }
            .frame(minHeight: Layout.timelineMinHeight)
        }
        .focusEffectDisabled()
        .sheet(isPresented: Bindable(editor).showExportDialog) {
            ExportView()
        }
    }
    private var panelDivider: some View {
        Rectangle()
            .fill(Color.black)
            .frame(width: 2)
    }
}
