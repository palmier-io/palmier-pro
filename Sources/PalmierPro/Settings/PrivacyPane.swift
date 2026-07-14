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
                title: "Share usage data",
                subtitle: "Send product usage data to help improve Palmier Pro. Media and project content are never included.",
                isOn: $analyticsEnabled
            )
            .onChange(of: analyticsEnabled) { _, newValue in
                Analytics.isEnabled = newValue
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)

            SettingsToggleRow(
                title: "Send crash reports",
                subtitle: "Send crash and error reports to help diagnose problems. Media and project content are never included.",
                isOn: $telemetryEnabled
            )
            .onChange(of: telemetryEnabled) { _, newValue in
                Telemetry.isEnabled = newValue
            }

            if telemetryDidChange {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    Text("Restart Palmier Pro to apply this change.")
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
    }
}
