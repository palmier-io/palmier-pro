import SwiftUI

struct ViewSkillsButton: View {
    enum Style {
        case titleBar
        case sidebar
    }

    var style: Style = .titleBar

    var body: some View {
        switch style {
        case .titleBar:
            titleBarButton
        case .sidebar:
            SidebarRowButton(label: "Skills", systemImage: "book.closed", action: openSkills)
        }
    }

    private var titleBarButton: some View {
        Button(action: openSkills) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "book.closed")
                Text("Skills")
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.IconSize.lg)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("View Skills")
    }

    private func openSkills() {
        SettingsWindowController.shared.show(tab: .skills)
    }
}
