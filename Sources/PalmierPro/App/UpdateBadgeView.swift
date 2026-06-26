import SwiftUI

struct UpdateSidebarCard: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        if updater.updateAvailable {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                        .foregroundStyle(AppTheme.Update.accent)
                        .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Update available")
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        if let version = updater.updateVersion {
                            Text("Version \(version) is ready to install.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.trailing, AppTheme.IconSize.sm)

                Button("Install Update") {
                    updater.checkForUpdates(nil)
                }
                .buttonStyle(.capsule(.prominent, size: .small))
                .frame(maxWidth: .infinity)
            }
            .padding(AppTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Update.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Update.border, lineWidth: AppTheme.BorderWidth.thin)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    updater.dismissUpdate()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .bold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .padding(AppTheme.Spacing.sm)
            }
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
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.down.circle.fill")
                        .offset(y: -1)
                    Text(badgeLabel)
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Update.accent)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: AppTheme.IconSize.lg)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppTheme.Update.accent.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(AppTheme.Update.accent.opacity(AppTheme.Opacity.moderate), lineWidth: AppTheme.BorderWidth.thin)
                )
                .help("Install update")
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity.combined(with: .scale))
        }
    }

    private var badgeLabel: String {
        if let version = updater.updateVersion {
            return "Update v\(version)"
        }
        return "Update available"
    }
}
