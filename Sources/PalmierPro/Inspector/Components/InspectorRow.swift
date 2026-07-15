import SwiftUI

/// A consistently aligned label and value row for editor panels.
struct InspectorRow<Trailing: View>: View {
    let label: String
    var labelHelp: String? = nil
    @ViewBuilder var trailing: () -> Trailing

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
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.EditorPanel.rowMinHeight)
    }
}
