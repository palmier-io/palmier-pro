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
                    Spacer(minLength: AppTheme.Spacing.zero)
                    Text(L10n.string("Elapsed: \(progress.elapsedSeconds(at: now))s"))
                        .monospacedDigit()
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
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.bottom, AppTheme.Spacing.smMd)
    }
}
