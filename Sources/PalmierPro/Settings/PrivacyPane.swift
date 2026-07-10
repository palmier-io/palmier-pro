import SwiftUI

struct PrivacyPane: View {
    @State private var telemetryEnabled: Bool = Telemetry.isEnabled
    @State private var analyticsEnabled: Bool = Analytics.isEnabled

    private var telemetryDidChange: Bool {
        telemetryEnabled != Telemetry.enabledForCurrentLaunch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SettingsToggleRow(
                title: "Share product telemetry",
                subtitle: "We do not collect media or project content.",
                isOn: $analyticsEnabled
            )
            .onChange(of: analyticsEnabled) { _, newValue in
                Analytics.isEnabled = newValue
            }

            SettingsToggleRow(
                title: "Send crash and error reports",
                subtitle: "Helps us find and fix issues by sharing crash and error reports. Your media and project content are never collected.",
                isOn: $telemetryEnabled
            )
            .onChange(of: telemetryEnabled) { _, newValue in
                Telemetry.isEnabled = newValue
            }

            if telemetryDidChange {
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
