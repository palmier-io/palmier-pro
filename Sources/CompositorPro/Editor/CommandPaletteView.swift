import SwiftUI

/// ⌘⇧P command palette: searchable actions with their keyboard hints.
struct CommandPaletteView: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0

    private var results: [AppCommand] { CommandRegistry.matches(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                TextField(L10n.string("Type a command"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.md))
                    .onSubmit { run(results.first) }
            }
            .padding(AppTheme.Spacing.md)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        Button {
                            run(command)
                        } label: {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Image(systemName: command.systemImage)
                                    .frame(width: 18)
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                                Text(L10n.string(key: command.titleKey))
                                    .font(.system(size: AppTheme.FontSize.sm))
                                Spacer()
                                if !command.shortcut.isEmpty {
                                    Text(verbatim: command.shortcut)
                                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.sm)
                            .background(index == highlighted ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.hint) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string(key: command.titleKey))
                        .accessibilityHint(Text(verbatim: command.shortcut))
                    }
                    if results.isEmpty {
                        Text(L10n.string("No matching commands"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .padding(AppTheme.Spacing.lg)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 420)
        .appSheetBackground()
    }

    private func run(_ command: AppCommand?) {
        guard let command else { return }
        CommandRegistry.perform(command.id, editor: editor)
        dismiss()
    }
}
