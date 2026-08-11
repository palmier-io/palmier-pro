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
                title: L10n.string("Share usage data"),
                subtitle: L10n.string("Send usage data from your interactions with Palmier Pro to help improve the app."),
                isOn: $analyticsEnabled
            )
            .onChange(of: analyticsEnabled) { _, newValue in
                Analytics.isEnabled = newValue
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)

            SettingsToggleRow(
                title: L10n.string("Send crash reports"),
                subtitle: L10n.string("Send crash and error reports to help diagnose problems. Media and project content are never included."),
                isOn: $telemetryEnabled
            )
            .onChange(of: telemetryEnabled) { _, newValue in
                Telemetry.isEnabled = newValue
            }

            if telemetryDidChange {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    Text(L10n.string("Restart Palmier Pro to apply this change."))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
    }
}
