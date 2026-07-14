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

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var unpaidSection: some View {
        accountSection(title: "Subscription") {
            if account.availablePlans.isEmpty {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Upgrade to Pro") {
                        Task { await account.subscribe(tier: .pro) }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .pointingHandCursor()

                    Button("Upgrade to Max") {
                        Task { await account.subscribe(tier: .max) }
                    }
                    .buttonStyle(accountSecondaryButtonStyle)
                    .pointingHandCursor()
                }
            } else {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    if let pro = account.availablePlan(for: .pro) {
                        planCard(plan: pro, isPrimary: true)
                    }
                    if let max = account.availablePlan(for: .max) {
                        planCard(plan: max, isPrimary: false)
                    }
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
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
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
            .pointingHandCursor()
        } else {
            Button {
                Task { await account.subscribe(tier: plan.tier) }
            } label: {
                Text(label).frame(maxWidth: .infinity)
            }
            .buttonStyle(accountSecondaryButtonStyle)
            .pointingHandCursor()
        }
    }

    private var subscriptionSection: some View {
        accountSection(title: "Subscription") {
            card {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(account.tier.planLabel)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.primaryColor)

                        if account.account?.user.cancelAtPeriodEnd == true,
                           let date = formattedPeriodEnd {
                            Text("Cancels \(date)")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    Button {
                        Task { await account.manageSubscription() }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text("Manage subscription")
                            Image(systemName: "arrow.up.right")
                                .font(.system(
                                    size: AppTheme.FontSize.xs,
                                    weight: AppTheme.FontWeight.semibold
                                ))
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(accountSecondaryButtonStyle)
                    .pointingHandCursor()
                }
            }
        }
    }

    private var creditsSection: some View {
        accountSection(title: "Credits") {
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

            Spacer(minLength: AppTheme.Spacing.sm)

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

            TopOffField(
                dollars: $topOffDollars,
                fieldFill: AppTheme.Background.raisedColor,
                buttonFill: accountSecondaryFill,
                showsExternalLinkIcon: true
            ) {
                account.buyCredits(dollars: topOffDollars)
            }

            Text("$\(TopOffLimits.minDollars)–$\(TopOffLimits.maxDollars) · Credits expire at renewal.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cardCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    private func accountSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
            content()
        }
    }

    private var accountSecondaryFill: AnyShapeStyle {
        AnyShapeStyle(AppTheme.Background.raisedColor)
    }

    private var accountSecondaryButtonStyle: CapsuleButtonStyle {
        .init(variant: .secondary, size: .regular, fill: accountSecondaryFill)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(AppTheme.Background.prominentColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
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
