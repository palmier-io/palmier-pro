import SwiftUI

struct UpdateBadgeView: View {
    @State private var updater = Updater.shared

    var body: some View {
        if updater.updateAvailable {
            HStack(spacing: 0) {
                Button {
                    updater.checkForUpdates(nil)
                } label: {
                    Text(badgeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.leading, AppTheme.Spacing.sm)
                        .padding(.trailing, 2)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Install update")

                Button {
                    updater.dismissUpdate()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 2)
                        .padding(.trailing, AppTheme.Spacing.xs)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .glassEffect(.regular, in: .capsule)
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
