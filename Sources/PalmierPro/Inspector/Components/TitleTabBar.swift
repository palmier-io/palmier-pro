import SwiftUI

struct TitleTabBar: View {
    let titles: [String]
    let selected: String?
    var raisedBackground: Bool = false
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ForEach(titles, id: \.self) { title in
                let isActive = selected == title
                let isAI = title == "AI Edit"
                let foreground: AnyShapeStyle = isAI
                    ? AnyShapeStyle(AppTheme.aiGradient.opacity(isActive ? 1 : 0.6))
                    : AnyShapeStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                Button {
                    onSelect(title)
                } label: {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Text(title)
                            .font(.system(size: AppTheme.FontSize.sm, weight: isActive ? .medium : .regular))
                            .foregroundStyle(foreground)
                        Rectangle()
                            .fill(isActive ? foreground : AnyShapeStyle(Color.clear))
                            .frame(height: AppTheme.BorderWidth.medium)
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.xs)
        .background(raisedBackground ? AppTheme.Background.raisedColor : Color.clear)
        .overlay(alignment: .bottom) {
            if raisedBackground {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
        }
    }
}
