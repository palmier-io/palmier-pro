import SwiftUI

struct MediaTabBar: View {
    @Binding var selected: ClipType
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClipType.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func tabButton(for tab: ClipType) -> some View {
        let isSelected = selected == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selected = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.sfSymbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color(nsColor: tab.themeColor)
                            : AppTheme.Text.tertiaryColor
                    )

                Text(tab.rawValue.capitalized)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? AppTheme.Text.primaryColor
                            : AppTheme.Text.tertiaryColor
                    )
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm - 1)
                        .fill(Color.white.opacity(0.08))
                        .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
