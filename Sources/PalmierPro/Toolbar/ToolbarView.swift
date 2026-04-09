import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.xs) {
                toolbarButton("arrow.uturn.backward", action: { editor.undoManager?.undo() })
                toolbarButton("arrow.uturn.forward", action: { editor.undoManager?.redo() })
            }

            themeDivider()

            // Tool mode
            HStack(spacing: 2) {
                toolModeButton("cursorarrow", mode: .pointer)
                toolModeButton("scissors", mode: .razor)
            }

            themeDivider()

            // Split at playhead
            toolbarButton("square.split.2x1", action: editor.splitAtPlayhead)

            Spacer()

            // Zoom
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .font(.system(size: AppTheme.FontSize.sm))
                @Bindable var ed = editor
                Slider(value: $ed.zoomScale, in: 0.5...20.0)
                    .controlSize(.mini)
                    .frame(width: 100)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .font(.system(size: AppTheme.FontSize.sm))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: 0.5)
        }
    }

    private func toolbarButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ToolbarHoverButtonStyle())
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode) -> some View {
        let isActive = editor.toolMode == mode
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .frame(width: 28, height: 28)
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(isActive ? Color.white.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func themeDivider() -> some View {
        Rectangle()
            .fill(AppTheme.Border.subtleColor)
            .frame(width: 0.5, height: 20)
    }
}

// MARK: - Hover button style

struct ToolbarHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed
                ? AppTheme.Text.primaryColor
                : AppTheme.Text.secondaryColor)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(configuration.isPressed
                        ? Color.white.opacity(0.1)
                        : isHovered ? Color.white.opacity(0.06) : .clear)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                    isHovered = hovering
                }
            }
    }
}
