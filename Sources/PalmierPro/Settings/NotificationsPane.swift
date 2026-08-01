import SwiftUI

struct NotificationsPane: View {
    @State private var notificationsEnabled: Bool = AppNotifications.isEnabled

    var body: some View {
        SettingsToggleRow(
            title: L10n.string("Show notifications"),
            subtitle: L10n.string("Get a notification when a generation finishes."),
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
