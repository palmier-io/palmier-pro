import SwiftUI

struct UpdateBadgeView: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        if updater.updateAvailable {
            HStack(spacing: 0) {
                Button {
                    updater.checkForUpdates(nil)
                } label: {
                    Text(badgeLabel)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, AppTheme.Spacing.sm)
                        .padding(.trailing, AppTheme.Spacing.xxs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Install update")

                Button {
                    updater.dismissUpdate()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .bold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.leading, AppTheme.Spacing.xxs)
                        .padding(.trailing, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .glassEffect(.regular, in: .capsule)
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity.combined(with: .scale))
        }
    }

    private var badgeLabel: String {
        if let v = updater.updateVersion {
            return "Update v\(v)"
        }
        return "Update available"
    }
}
