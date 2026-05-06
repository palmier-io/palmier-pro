import SwiftUI

struct NotificationsPane: View {
    @State private var notificationsEnabled: Bool = AppNotifications.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SettingsToggleRow(
                title: "Show notifications",
                subtitle: "Notify when generated media is ready.",
                isOn: $notificationsEnabled
            )
            .onChange(of: notificationsEnabled) { _, newValue in
                AppNotifications.isEnabled = newValue
                if newValue {
                    AppNotifications.configure()
                }
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)
        }
    }
}
