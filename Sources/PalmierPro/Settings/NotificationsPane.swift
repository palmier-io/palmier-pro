import SwiftUI

struct NotificationsPane: View {
    @State private var notificationsEnabled: Bool = AppNotifications.isEnabled

    var body: some View {
        SettingsToggleRow(
            title: "Show notifications",
            subtitle: "Get a notification when a generation finishes.",
            isOn: $notificationsEnabled
        )
        .onChange(of: notificationsEnabled) { _, newValue in
            AppNotifications.isEnabled = newValue
            if newValue {
                AppNotifications.configure()
            }
        }
    }
}
