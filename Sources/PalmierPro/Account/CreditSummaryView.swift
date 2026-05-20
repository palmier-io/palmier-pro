import SwiftUI

/// Compact "X / Y credits used" pill with a progress bar underneath.
/// Hides when the user has no active plan or the budget is unknown.
struct CreditSummaryView: View {
    enum Style {
        case full   // settings: bigger title + progress bar
        case compact // generation panel header chip
    }

    let style: Style
    @Bindable private var account = AccountService.shared

    var body: some View {
        if let budget = account.budgetCredits, account.isPaid {
            let left = max(0, budget - account.spentCredits)
            let remaining = budget > 0 ? min(1.0, Double(left) / Double(budget)) : 0
            switch style {
            case .full: fullView(left: left, budget: budget, remaining: remaining)
            case .compact: compactView(left: left, budget: budget, remaining: remaining)
            }
        }
    }

    private func fullView(left: Int, budget: Int, remaining: Double) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Credits")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Text("\(left.formatted()) / \(budget.formatted())")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(barColor(remaining))
            }
            ProgressView(value: remaining)
                .progressViewStyle(.linear)
                .tint(barColor(remaining))
        }
    }

    private func compactView(left: Int, budget: Int, remaining: Double) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(barColor(remaining))
            Text(left.formatted())
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(barColor(remaining))
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule().stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
        )
        .help("\(left.formatted()) of \(budget.formatted()) credits remaining this period")
    }

    /// Tint by remaining ratio — full bar is healthy, drained bar is alarming.
    private func barColor(_ remaining: Double) -> Color {
        switch remaining {
        case ..<0.05: return .red
        case ..<0.25: return .orange
        default: return .accentColor
        }
    }
}
