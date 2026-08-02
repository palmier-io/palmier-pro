import SwiftUI

struct TitleTabBar: View {
    let titles: [String]
    let selected: String?
    var tourAnchors: [String: TourAnchorID] = [:]
    let onSelect: (String) -> Void
    @State private var hoveredTitle: String?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            ForEach(titles, id: \.self) { title in
                tab(title)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.panelHeaderHeight)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.thin)
        }
    }

    @ViewBuilder
    private func tab(_ title: String) -> some View {
        let active = selected == title
        let hovered = hoveredTitle == title
        let button = Button {
            onSelect(title)
        } label: {
            Text(L10n.string(key: title))
                .font(.system(size: AppTheme.FontSize.sm, weight: active ? AppTheme.FontWeight.medium : AppTheme.FontWeight.regular))
                .lineLimit(1)
                .foregroundStyle(active ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tabBackground(active: active, hovered: hovered))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? AppTheme.Accent.primary : Color.clear)
                        .frame(height: AppTheme.BorderWidth.thick)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredTitle = hovering ? title : (hoveredTitle == title ? nil : hoveredTitle)
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: hovered)
        if let anchor = tourAnchors[title] {
            button.tourAnchor(anchor)
        } else {
            button
        }
    }

    private func tabBackground(active: Bool, hovered: Bool) -> Color {
        if active { return AppTheme.Background.surfaceColor }
        if hovered { return AppTheme.Interaction.fill(AppTheme.Opacity.faint) }
        return Color.clear
    }
}
