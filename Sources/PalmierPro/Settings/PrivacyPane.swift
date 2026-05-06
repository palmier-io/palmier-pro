import SwiftUI

struct PrivacyPane: View {
    @State private var telemetryEnabled: Bool = Telemetry.isEnabled

    private var didChange: Bool {
        telemetryEnabled != Telemetry.enabledForCurrentLaunch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("Privacy")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            .padding(.leading, AppTheme.Spacing.xs)

            Toggle(isOn: $telemetryEnabled) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Send anonymous crash and error reports")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Helps us find and fix issues faster. We use Sentry for crash reports and never collect your media or project content.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: telemetryEnabled) { _, newValue in
                Telemetry.isEnabled = newValue
            }

            if didChange {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                    Text("Restart Palmier Pro to apply this change.")
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
    }
}
