import SwiftUI

struct AccountPane: View {
    @Bindable var account = AccountService.shared
    @State private var topOffDollars: Int = 20

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if account.isLoading {
                Text("Loading…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if account.isSignedIn {
                signedInBody
            } else {
                signedOutBody
            }

            if let error = account.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    @ViewBuilder
    private var signedInBody: some View {
        if account.isPaid {
            subscriptionSection
            creditsSection
        } else {
            unpaidSection
        }

        Button("Sign out") {
            Task { await account.signOut() }
        }
        .buttonStyle(.capsule(.secondary, size: .regular))
    }

    @ViewBuilder
    private var unpaidSection: some View {
        SettingsSection(title: "Subscription") {
            Text("Subscribe to use AI generation.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            if account.availablePlans.isEmpty {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Upgrade to Pro") {
                        Task { await account.subscribe(tier: .pro) }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))

                    Button("Upgrade to Max") {
                        Task { await account.subscribe(tier: .max) }
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                }
            } else {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    if let pro = account.availablePlan(for: .pro) {
                        planCard(plan: pro, isPrimary: true)
                            .frame(maxWidth: 180)
                    }
                    if let max = account.availablePlan(for: .max) {
                        planCard(plan: max, isPrimary: false)
                            .frame(maxWidth: 180)
                    }
                    Spacer(minLength: 0)
                }

                Text("Credits cover AI generation and chat.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func planCard(plan: AvailablePlan, isPrimary: Bool) -> some View {
        card {
            cardCaption(plan.tier.planLabel)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                Text("$\(plan.effectiveMonthlyPriceUsd)")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if plan.hasDiscount {
                    Text("$\(plan.monthlyPriceUsd)")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .strikethrough()
                }
                Text("/ month")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            if let credits = plan.monthlyBudgetCredits {
                Text("\(credits.formatted()) credits / month")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .monospacedDigit()
            }

            Spacer(minLength: AppTheme.Spacing.xs)

            upgradeButton(for: plan, isPrimary: isPrimary)
        }
    }

    @ViewBuilder
    private func upgradeButton(for plan: AvailablePlan, isPrimary: Bool) -> some View {
        let label = "Upgrade to \(plan.tier.upgradeLabel)"
        if isPrimary {
            Button {
                Task { await account.subscribe(tier: plan.tier) }
            } label: {
                Text(label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
        } else {
            Button {
                Task { await account.subscribe(tier: plan.tier) }
            } label: {
                Text(label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        SettingsSection(title: "Subscription") {
            Text(account.tier.planLabel)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            if account.account?.user.cancelAtPeriodEnd == true,
               let date = formattedPeriodEnd {
                Text("Cancels \(date)")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.orange)
            }

            Button("Manage subscription") {
                Task { await account.manageSubscription() }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
        }
    }

    @ViewBuilder
    private var creditsSection: some View {
        SettingsSection(title: "Credits") {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                remainingCard
                buyCard
            }
        }
    }

    @ViewBuilder
    private var remainingCard: some View {
        card {
            cardCaption("Remaining")

            CreditSummaryView(style: .full)

            Spacer(minLength: AppTheme.Spacing.sm)

            if let date = formattedPeriodEnd {
                Text("Resets \(date)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    @ViewBuilder
    private var buyCard: some View {
        card {
            cardCaption("Buy more")

            TopOffField(dollars: $topOffDollars) {
                account.buyCredits(dollars: topOffDollars)
            }

            Text("$\(TopOffLimits.minDollars)–$\(TopOffLimits.maxDollars) · Unused credits expire at your next billing date.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cardCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private var formattedPeriodEnd: String? {
        guard let endMs = account.account?.user.currentPeriodEnd else { return nil }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        return end.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var signedOutBody: some View {
        Text("Sign in to subscribe and use AI generation.")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)

        Button(account.isSigningIn ? "Opening Google…" : "Sign in with Google") {
            Task { await account.signInWithGoogle() }
        }
        .buttonStyle(.capsule(.secondary, size: .regular))
        .disabled(account.isSigningIn)
        .padding(.top, AppTheme.Spacing.xs)
    }
}
