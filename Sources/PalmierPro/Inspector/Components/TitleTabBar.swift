import SwiftUI

struct TitleTabBar: View {
    struct Item: Identifiable {
        let titleKey: String
        let systemImage: String

        var id: String { titleKey }
    }

    let items: [Item]
    let selected: String?
    var tourAnchors: [String: TourAnchorID] = [:]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            ForEach(items) { item in
                tab(item)
            }
        }
        .panelHeaderBar()
    }

    @ViewBuilder
    private func tab(_ item: Item) -> some View {
        let active = selected == item.id
        let button = Button {
            onSelect(item.id)
        } label: {
            VStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: item.systemImage)
                    .font(.system(
                        size: AppTheme.FontSize.xs,
                        weight: active ? AppTheme.FontWeight.medium : AppTheme.FontWeight.regular
                    ))
                    .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                    .accessibilityHidden(true)
                Text(L10n.string(key: item.titleKey))
                    .font(.system(
                        size: AppTheme.FontSize.xxs,
                        weight: active ? AppTheme.FontWeight.medium : AppTheme.FontWeight.regular
                    ))
            }
            .lineLimit(1)
            .foregroundStyle(active ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? AppTheme.Text.primaryColor : Color.clear)
                    .frame(height: AppTheme.BorderWidth.thin)
                    .offset(y: -AppTheme.BorderWidth.thin)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(L10n.string(key: item.titleKey))
        .accessibilityAddTraits(active ? .isSelected : [])
        if let anchor = tourAnchors[item.id] {
            button.tourAnchor(anchor)
        } else {
            button
        }
    }
}
