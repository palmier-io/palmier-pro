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
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")

            Button(action: { AppState.shared.showHome() }) {
                Image(systemName: "house")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Home")

            ProjectActivityButton()
        }
        .padding(.leading, AppTheme.Spacing.sm)
    }
}

struct TitleBarTrailingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer(minLength: 0)

            UpdateBadgeView()

            LayoutPresetMenu()

            Button(action: { editor.showExportDialog = true }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
                    .help("Export (⌘E)")
            }
            .buttonStyle(.plain)

            UserAvatarButton()
        }
    }
}

// MARK: - Layout preset menu

struct LayoutPresetMenu: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        Menu {
            ForEach(LayoutPreset.allCases, id: \.self) { preset in
                Button {
                    editor.layoutPreset = preset
                } label: {
                    HStack {
                        Image(systemName: preset.icon)
                        Text(preset.label)
                    }
                }
                .disabled(editor.layoutPreset == preset)
            }
        } label: {
            Image(systemName: editor.layoutPreset.icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .help("Layout")
    }
}
