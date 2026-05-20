import SwiftUI

struct AccountPane: View {
    @Bindable var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
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
            paidActions
        } else {
            unpaidActions
        }

        Divider().overlay(AppTheme.Border.subtleColor).padding(.vertical, AppTheme.Spacing.sm)

        Button("Sign out") {
            Task { await account.signOut() }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var unpaidActions: some View {
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
        .padding(.top, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private var paidActions: some View {
        CreditSummaryView(style: .full)
            .padding(.bottom, AppTheme.Spacing.xs)

        if let periodMessage {
            Text(periodMessage)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }

        Text("Manage billing, switch plans, or cancel subscription.")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)

        Button("Manage subscription") {
            Task { await account.manageSubscription() }
        }
        .buttonStyle(.bordered)
        .padding(.top, AppTheme.Spacing.xs)
    }

    private var periodMessage: String? {
        guard let endMs = account.account?.user.currentPeriodEnd else { return nil }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        let formatted = end.formatted(date: .abbreviated, time: .omitted)
        if account.account?.user.cancelAtPeriodEnd == true {
            return "Cancels on \(formatted)."
        }
        return "Next billing on \(formatted)."
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
