import SwiftUI

struct PanelSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil
    var onClear: (() -> Void)? = nil
    var onExit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            textField
            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.string("Clear search"))
            }
        }
        .padding(.leading, AppTheme.Spacing.smMd)
        .padding(.trailing, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    AppTheme.Interaction.fill(AppTheme.Opacity.faint),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        )
    }

    @ViewBuilder
    private var textField: some View {
        let field = TextField(L10n.string("Search"), text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.primaryColor)

        if let focus, let onExit {
            field
                .focused(focus)
                .onExitCommand(perform: onExit)
        } else if let focus {
            field.focused(focus)
        } else if let onExit {
            field.onExitCommand(perform: onExit)
        } else {
            field
        }
    }

    private func clear() {
        if let onClear {
            onClear()
        } else {
            text = ""
        }
    }
}
