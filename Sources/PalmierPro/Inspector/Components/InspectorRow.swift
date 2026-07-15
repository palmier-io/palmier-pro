import SwiftUI

/// A consistently aligned label and value row for editor panels.
struct InspectorRow<Trailing: View>: View {
    let label: String
    let labelHelp: String?
    let onReset: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    init(
        label: String,
        labelHelp: String? = nil,
        onReset: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.label = label
        self.labelHelp = labelHelp
        self.onReset = onReset
        self.trailing = trailing
    }

    @ViewBuilder
    var body: some View {
        if let labelHelp {
            row.help(labelHelp)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .frame(width: AppTheme.EditorPanel.labelColumnWidth, alignment: .trailing)

            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)

            if let onReset {
                EditorResetButton(title: label, action: onReset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.EditorPanel.rowMinHeight)
    }
}

struct EditorResetButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Reset \(title.lowercased())")
        .accessibilityLabel("Reset \(title)")
    }
}
