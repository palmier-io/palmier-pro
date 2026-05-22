import SwiftUI

/// Compact account summary shown when the user clicks the IdentityStrip avatar.
struct AccountPopoverCard: View {
    @Bindable private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss

    private static let cardWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            identityBlock

            if account.isSignedIn {
                Divider().overlay(AppTheme.Border.subtleColor)
                planBlock
            }

            Divider().overlay(AppTheme.Border.subtleColor)
            footerRow

            if let error = account.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.red)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: Self.cardWidth)
        .focusEffectDisabled()
    }

    // MARK: - Identity (mirrors IdentityStrip layout)

    private var identityBlock: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            UserAvatar(
                diameter: AppTheme.IconSize.xl,
                fontSize: AppTheme.FontSize.mdLg
            )
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
    }

    // MARK: - Plan + credit info

    private var planBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text(account.tier.planLabel)
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: 0)
                if account.account?.user.cancelAtPeriodEnd == true,
                   let date = formattedPeriodEnd {
                    Text("Cancels \(date)")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(.orange)
                }
            }

            creditsBlock

            if !account.isPaid {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Upgrade to Pro") {
                        Task { await account.subscribe(tier: .pro) }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Max") {
                        Task { await account.subscribe(tier: .max) }
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var creditsBlock: some View {
        if let budget = account.budgetCredits, account.isPaid {
            let left = max(0, budget - account.spentCredits)
            let remaining = budget > 0 ? min(1.0, Double(left) / Double(budget)) : 0
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ProgressView(value: remaining)
                    .progressViewStyle(.linear)
                    .tint(barColor(remaining))
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("\(left.formatted()) / \(budget.formatted()) credits")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: 0)
                    if let date = formattedPeriodEnd {
                        Text("Resets \(date)")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
        }
    }

    private func barColor(_ remaining: Double) -> Color {
        switch remaining {
        case ..<0.05: return .red
        case ..<0.25: return .orange
        default: return AppTheme.Accent.primary
        }
    }

    // MARK: - Footer (Settings + Sign in / Sign out)

    private var footerRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            footerButton(label: "Settings", systemImage: "gearshape") {
                SettingsWindowController.shared.show()
                dismiss()
            }
            Spacer(minLength: 0)
            if account.isSignedIn {
                footerButton(label: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await account.signOut() }
                    dismiss()
                }
            } else {
                footerButton(label: "Sign in", systemImage: "person.crop.circle") {
                    Task { await account.signInWithGoogle() }
                    dismiss()
                }
            }
        }
    }

    private func footerButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd))
                Text(label)
                    .font(.system(size: AppTheme.FontSize.sm))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }

    private var formattedPeriodEnd: String? {
        guard let endMs = account.account?.user.currentPeriodEnd else { return nil }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        return end.formatted(date: .abbreviated, time: .omitted)
    }
}
