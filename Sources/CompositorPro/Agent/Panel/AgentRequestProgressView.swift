import SwiftUI

struct AgentRequestProgressView: View {
    let progress: AgentRequestProgress

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = ContinuousClock.now
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(progress.phase.displayText)
                        .lineLimit(1)
                        .help(progress.phase.displayText)
                    Spacer(minLength: AppTheme.Spacing.zero)
                    Text(L10n.string("\(progress.elapsedSeconds(at: now))s"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .monospacedDigit()
                        .accessibilityLabel(L10n.string("Elapsed: \(progress.elapsedSeconds(at: now))s"))
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                if let retry = progress.retry {
                    Text(retry.displayText)
                        .font(.system(size: AppTheme.FontSize.sm))
                }
                if let detail = progress.detail(at: now) {
                    Text(detail)
                        .font(.system(size: AppTheme.FontSize.sm))
                }
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.smMd)
            .background(AppTheme.Background.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
    }
}
