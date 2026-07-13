import SwiftUI

struct UpdateSidebarCard: View {
    @Bindable private var updater = Updater.shared
    @State private var isHovering = false

    var body: some View {
        if updater.updateAvailable {
            Button {
                updater.checkForUpdates(nil)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Click to install update")
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(updater.updateVersion.map { "Version \($0)" } ?? "New version available")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.md)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(isHovering ? AppTheme.Background.prominentColor : AppTheme.Background.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovering)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

struct UpdateProjectBadge: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        if updater.updateAvailable {
            Button {
                updater.checkForUpdates(nil)
            } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .foregroundStyle(AppTheme.Update.accent)
                    .lineLimit(1)
                    .padding(.horizontal, AppTheme.Spacing.smMd)
                    .frame(height: AppTheme.IconSize.lg)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.Update.accent.opacity(AppTheme.Opacity.muted))
                    )
            }
            .buttonStyle(.plain)
            .help(helpText)
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity.combined(with: .scale))
        }
    }

    private var helpText: String {
        if let version = updater.updateVersion {
            return "Install update v\(version)"
        }
        return "Install update"
    }
}
