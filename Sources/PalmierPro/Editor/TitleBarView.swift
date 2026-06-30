import SwiftUI

struct TitleBarLeadingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Button(action: { editor.agentPanelVisible.toggle() }) {
                Image(systemName: editor.agentPanelVisible ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.aiGradient)
                    .opacity(editor.agentPanelVisible ? 1 : AppTheme.Opacity.strong)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")
        }
    }
}

struct TitleBarTrailingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer(minLength: 0)

            UpdateBadgeView()

            Button(action: { editor.showExportDialog = true }) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "square.and.arrow.up")
                    .offset(y: -1)
                    Text("Export")
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: AppTheme.IconSize.lg)
                .hoverHighlight()
                .help("Export (⌘E)")
            }
            .buttonStyle(.plain)

            UserAvatarButton()
        }
    }
}
