import SwiftUI

struct IdentityStrip: View {
    @Bindable private var account = AccountService.shared

    var body: some View {
        let labels = labels(for: account.account?.user)

        HStack(spacing: 10) {
            avatar(initial: labels.initial)
            VStack(alignment: .leading, spacing: 1) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func avatar(initial: String) -> some View {
        ZStack {
            Circle()
                .fill(account.isSignedIn ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.10))
            Text(initial)
                .font(.system(size: 14, weight: .semibold))
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
        .frame(width: 30, height: 30)
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
