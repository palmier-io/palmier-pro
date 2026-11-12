import SwiftUI

struct NotificationsPane: View {
    @State private var notificationsEnabled: Bool = AppNotifications.isEnabled
    @State private var agentSoundEnabled: Bool = AppNotifications.agentSoundEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
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
            SettingsToggleRow(
                title: L10n.string("Play a sound when the agent finishes"),
                subtitle: L10n.string("An audible cue that a request is done, for when you look away."),
                isOn: $agentSoundEnabled
            )
            .onChange(of: agentSoundEnabled) { _, newValue in
                AppNotifications.agentSoundEnabled = newValue
            }
        }
    }
}
