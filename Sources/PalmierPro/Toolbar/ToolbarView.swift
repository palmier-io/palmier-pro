import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("arrow.uturn.backward", action: { editor.undoManager?.undo() })
                toolbarButton("arrow.uturn.forward", action: { editor.undoManager?.redo() })
            }

            // Tool mode
            HStack(spacing: AppTheme.Spacing.md) {
                toolModeButton("cursorarrow", mode: .pointer)
                toolModeButton("scissors", mode: .razor)
            }

            // Split at playhead
            toolbarButton("square.split.2x1", action: editor.splitAtPlayhead)

            Spacer()

            // Zoom
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .font(.system(size: AppTheme.FontSize.sm))
                @Bindable var ed = editor
                Slider(value: $ed.zoomScale, in: editor.minZoomScale...Zoom.max)
                    .controlSize(.mini)
                    .frame(width: 100)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .font(.system(size: AppTheme.FontSize.sm))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbarButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .frame(width: 24, height: 24)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode) -> some View {
        let isActive = editor.toolMode == mode
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .frame(width: 24, height: 24)
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
        }
        .buttonStyle(.plain)
    }

}
