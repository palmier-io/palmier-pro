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
                    .foregroundStyle(.red)
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
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var unpaidSection: some View {
        section(title: "Subscription") {
            Text("Subscribe to unlock AI generation features.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Subscribe Pro") {
                    Task { await account.subscribe(tier: .pro) }
                }
                .buttonStyle(.borderedProminent)

                Button("Subscribe Max") {
                    Task { await account.subscribe(tier: .max) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        section(title: "Subscription") {
            Text(account.tier.planLabel)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            if account.account?.user.cancelAtPeriodEnd == true,
               let date = formattedPeriodEnd {
                Text("Cancels on \(date).")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.orange)
            }

            Button("Manage subscription") {
                Task { await account.manageSubscription() }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var creditsSection: some View {
        section(title: "Credits") {
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

            HStack(spacing: AppTheme.Spacing.sm) {
                Text("$")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("", value: $topOffDollars, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .disabled(account.isBuyingCredits)
                Text("= \(topOffCredits.formatted()) credits")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .monospacedDigit()
                    .foregroundStyle(
                        isValidTopOff
                            ? AppTheme.Text.secondaryColor
                            : AppTheme.Text.tertiaryColor
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Button {
                account.buyCredits(dollars: topOffDollars)
            } label: {
                Text(buyButtonLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(account.isBuyingCredits || !isValidTopOff)

            Text("$\(TopOffLimits.minDollars)–$\(TopOffLimits.maxDollars). Unused credits reset at the next billing cycle.")
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

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private var topOffCredits: Int { max(0, topOffDollars) * 100 }

    private var isValidTopOff: Bool {
        (TopOffLimits.minDollars...TopOffLimits.maxDollars).contains(topOffDollars)
    }

    private var buyButtonLabel: String {
        isValidTopOff ? "Buy $\(topOffDollars)" : "Buy"
    }

    private var formattedPeriodEnd: String? {
        guard let endMs = account.account?.user.currentPeriodEnd else { return nil }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        return end.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var signedOutBody: some View {
        Text("Sign in to subscribe to Palmier. Required for AI generation features.")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)

        Button("Sign in with Google") {
            Task { await account.signInWithGoogle() }
        }
        .buttonStyle(.bordered)
        .padding(.top, AppTheme.Spacing.xs)
    }
}
