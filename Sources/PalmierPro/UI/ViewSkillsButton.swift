import SwiftUI

struct ViewSkillsButton: View {
    var body: some View {
        Button(action: openSkills) {
            Image(systemName: "book.closed")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("View Skills")
        .tourAnchor(.skillsButton)
    }

    private func openSkills() {
        SettingsWindowController.shared.show(tab: .skills)
    }
}
