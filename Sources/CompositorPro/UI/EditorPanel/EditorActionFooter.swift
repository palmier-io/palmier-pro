import SwiftUI

struct EditorActionFooter<Actions: View>: View {
    let message: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let message {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

struct EditorAgentMenu<MenuContent: View>: View {
    let help: String
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("Agent Mode"))
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xs))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .lineLimit(1)
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.capsule(.secondary))
        .menuIndicator(.hidden)
        .focusable(false)
        .help(L10n.string(key: help))
        .accessibilityLabel(L10n.string("Agent Mode"))
    }
}
