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
                    .font(.system(size: AppTheme.FontSize.md))
                    .frame(width: AppTheme.IconSize.sm)
                Text(label)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .hoverHighlight(cornerRadius: AppTheme.Radius.xl, isActive: isSelected)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
