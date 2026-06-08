import SwiftUI

/// `[icon] Label                                    trailing`
struct InspectorRow<Trailing: View>: View {
    let icon: String
    let label: String
    var labelHelp: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 16, alignment: .leading)
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if let labelHelp {
                Image(systemName: "info.circle")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    .contentShape(Rectangle())
                    .help(labelHelp)
            }
            Spacer()
            trailing()
        }
    }
}

extension InspectorRow where Trailing == EmptyView {
    init(icon: String, label: String) {
        self.init(icon: icon, label: label, trailing: { EmptyView() })
    }
}
