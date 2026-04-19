import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("arrow.uturn.backward", action: { editor.undoManager?.undo() })
                toolbarButton("arrow.uturn.forward", action: { editor.undoManager?.redo() })
            }

            Divider()
                .frame(height: 20)

            // Tool mode
            HStack(spacing: AppTheme.Spacing.md) {
                toolModeButton("cursorarrow", mode: .pointer)
                toolModeButton("scissors", mode: .razor)
            }

            Divider()
                .frame(height: 20)

            // Split, trim buttons
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("square.split.2x1", action: editor.splitAtPlayhead)
                bracketButton("[", action: editor.trimStartToPlayhead)
                bracketButton("]", action: editor.trimEndToPlayhead)
            }

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
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbarButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode) -> some View {
        let isActive = editor.toolMode == mode
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight(isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    private func bracketButton(_ bracket: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(bracket)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
    }

}
