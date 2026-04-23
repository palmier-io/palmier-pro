import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("arrow.uturn.backward", help: "Undo (⌘Z)", action: { editor.undoManager?.undo() })
                toolbarButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: { editor.undoManager?.redo() })
            }

            Divider()
                .frame(height: 20)

            // Tool mode
            HStack(spacing: AppTheme.Spacing.md) {
                toolModeButton("cursorarrow", mode: .pointer, help: "Pointer (V)")
                toolModeButton("scissors", mode: .razor, help: "Razor (C)")
            }

            Divider()
                .frame(height: 20)

            // Split, trim buttons
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("square.split.2x1", help: "Split at Playhead (⌘K)", action: editor.splitAtPlayhead)
                bracketButton("[", help: "Trim Start to Playhead (Q)", action: editor.trimStartToPlayhead)
                bracketButton("]", help: "Trim End to Playhead (W)", action: editor.trimEndToPlayhead)
            }

            Divider()
                .frame(height: 20)

            // Capture current frame to media panel
            toolbarButton("camera", help: "Capture Frame to Media", action: editor.captureCurrentFrameToMedia)

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

    private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
                .help(help)
        }
        .buttonStyle(.plain)
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode, help: String) -> some View {
        let isActive = editor.toolMode == mode
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight(isActive: isActive)
                .help(help)
        }
        .buttonStyle(.plain)
    }

    private func bracketButton(_ bracket: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(bracket)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
                .help(help)
        }
        .buttonStyle(.plain)
    }

}
