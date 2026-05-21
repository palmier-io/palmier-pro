import SwiftUI

struct SidebarRowButton: View {
    let label: String
    let systemImage: String
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: AppTheme.FontSize.md))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .hoverHighlight(cornerRadius: 5, isActive: isSelected)
        }
        .buttonStyle(.plain)
    }
}
