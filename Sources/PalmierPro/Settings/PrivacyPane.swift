import SwiftUI

struct PrivacyPane: View {
    @State private var telemetryEnabled: Bool = Telemetry.isEnabled

    private var didChange: Bool {
        telemetryEnabled != Telemetry.enabledForCurrentLaunch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SettingsToggleRow(
                title: "Send anonymous crash and error reports",
                subtitle: "Helps us find and fix issues. Crash reports go to Sentry. Your media and project content are never collected.",
                isOn: $telemetryEnabled
            )
            .onChange(of: telemetryEnabled) { _, newValue in
                Telemetry.isEnabled = newValue
            }

            if didChange {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    Text("Restart Palmier Pro to apply this change.")
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.top, AppTheme.Spacing.xs)
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)
        }
    }
}
