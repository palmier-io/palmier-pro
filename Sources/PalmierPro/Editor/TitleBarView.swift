import SwiftUI

struct TitleBarLeadingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Button(action: { editor.agentPanelVisible.toggle() }) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: editor.agentPanelVisible ? "bubble.left.fill" : "bubble.left")
                        .foregroundStyle(AppTheme.aiGradient)
                        .opacity(editor.agentPanelVisible ? 1 : AppTheme.Opacity.strong)
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    Text(L10n.string("Chat"))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: AppTheme.IconSize.lg)
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help(L10n.string("Toggle Agent Panel"))

            HStack(spacing: AppTheme.Spacing.xxs) {
                PanelVisibilityButton(
                    systemName: "sidebar.left",
                    label: L10n.string("Media Panel"),
                    isVisible: editor.mediaPanelVisible
                ) {
                    editor.mediaPanelVisible.toggle()
                }
                PanelVisibilityButton(
                    systemName: "sidebar.right",
                    label: L10n.string("Inspector Panel"),
                    isVisible: editor.inspectorPanelVisible
                ) {
                    editor.inspectorPanelVisible.toggle()
                }
            }
        }
    }
}

struct TitleBarTrailingView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var exportQueue = ExportQueue.shared

    var body: some View {
        let jobs = exportQueue.jobs(for: editor.exportQueueProjectID)
        let activeCount = jobs.count { $0.status.isRunning }
        let waitingCount = jobs.count { $0.status == .waiting }

        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer(minLength: AppTheme.Spacing.zero)

            UpdateProjectBadge()

            Button(action: { editor.showExportDialog = true }) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Group {
                        if activeCount > 0 {
                            exportActivityDot
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .offset(y: -1)
                        }
                    }
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    Text(L10n.string("Export"))
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: AppTheme.IconSize.lg)
                .hoverHighlight()
                .help(L10n.string("Export (⌘E)"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                activeCount == 0 && waitingCount == 0
                    ? L10n.string("Export")
                    : L10n.string("Export, \(activeCount) active, \(waitingCount) waiting")
            )

            UserAvatarButton()
        }
    }

    private var exportActivityDot: some View {
        PhaseAnimator([false, true]) { dimmed in
            Circle()
                .fill(AppTheme.Status.warningColor)
                .frame(width: AppTheme.Export.activityDotSize, height: AppTheme.Export.activityDotSize)
                .opacity(dimmed ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
        } animation: { _ in
            .easeInOut(duration: AppTheme.Anim.pulse)
        }
        .accessibilityHidden(true)
    }
}

private struct PanelVisibilityButton: View {
    let systemName: String
    let label: String
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(isVisible ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(isVisible ? .isSelected : [])
        .help(label)
    }
}
