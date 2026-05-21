import SwiftUI

struct SidebarRowButton: View {
    let label: String
    let systemImage: String
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .frame(width: AppTheme.Spacing.lgXl)
                Text(label)
                    .font(.system(size: AppTheme.FontSize.md))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: isSelected)
        }
        .buttonStyle(.plain)
    }
}
