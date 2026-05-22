import SwiftUI

// MARK: - UserAvatar

struct UserAvatar: View {
    enum SignedOutStyle {
        case filledCircle
        case bareSymbol
    }

    var diameter: CGFloat
    var fontSize: CGFloat
    var signedOutStyle: SignedOutStyle = .filledCircle

    @Bindable private var account = AccountService.shared

    var body: some View {
        ZStack {
            background
            foreground
            profileImage
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var background: some View {
        if account.isSignedIn {
            Circle().fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium))
        } else if signedOutStyle == .filledCircle {
            Circle().fill(Color.white.opacity(AppTheme.Opacity.soft))
        }
    }

    @ViewBuilder
    private var foreground: some View {
        if account.isSignedIn {
            Text(account.displayInitial)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
        } else {
            switch signedOutStyle {
            case .filledCircle:
                Image(systemName: "person.fill")
                    .font(.system(size: fontSize))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            case .bareSymbol:
                Image(systemName: "person.crop.circle")
                    .font(.system(size: diameter))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }

    @ViewBuilder
    private var profileImage: some View {
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
}

// MARK: - UserAvatarButton

struct UserAvatarButton: View {
    @Bindable private var account = AccountService.shared
    @State private var isPopoverPresented = false

    var body: some View {
        Button(action: { isPopoverPresented.toggle() }) {
            UserAvatar(
                diameter: AppTheme.IconSize.sm,
                fontSize: AppTheme.FontSize.xxs,
                signedOutStyle: .bareSymbol
            )
            .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(account.isSignedIn ? "Account" : "Sign in")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            AccountPopoverCard()
        }
    }
}

// MARK: - IdentityStrip

struct IdentityStrip: View {
    @Bindable private var account = AccountService.shared
    @State private var isPopoverPresented = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Button(action: { isPopoverPresented.toggle() }) {
                UserAvatar(
                    diameter: AppTheme.IconSize.xl,
                    fontSize: AppTheme.FontSize.mdLg
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                AccountPopoverCard()
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(account.displayPrimaryText)
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = account.displaySecondaryText {
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
}
