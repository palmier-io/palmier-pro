import SwiftUI

struct IdentityStrip: View {
    @Bindable private var account = AccountService.shared

    var body: some View {
        let labels = labels(for: account.account?.user)

        HStack(spacing: AppTheme.Spacing.md) {
            avatar(initial: labels.initial)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(labels.primary)
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = labels.secondary {
                    Text(secondary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private func avatar(initial: String) -> some View {
        ZStack {
            Circle()
                .fill(account.isSignedIn ? Color.accentColor.opacity(AppTheme.Opacity.medium) : Color.white.opacity(AppTheme.Opacity.soft))
            Text(initial)
                .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            if let urlString = account.account?.user.image,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
                .id(urlString)
            }
        }
        .frame(width: AppTheme.IconSize.xl, height: AppTheme.IconSize.xl)
        .clipShape(Circle())
    }

    private struct Labels {
        let primary: String
        let secondary: String?
        let initial: String
    }

    private func labels(for user: AccountUser?) -> Labels {
        let name = user?.displayName
        let email = user?.email
        let primary = name ?? email ?? "Anonymous"
        let secondary = name != nil ? email : nil
        let initial = (name ?? email)?.first.map { String($0).uppercased() } ?? "?"
        return Labels(primary: primary, secondary: secondary, initial: initial)
    }
}
