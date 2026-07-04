import SwiftUI

struct TabStrip<Item: Identifiable, Tab: View, Trailing: View>: View where Item.ID == String {
    let items: [Item]
    let activeId: String
    var scrollRequest: String? = nil
    @ViewBuilder let tab: (Item) -> Tab
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.md) {
                    ForEach(items) { item in
                        tab(item).id(item.id)
                    }
                    trailing()
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
            }
            .mouseWheelScrollsHorizontally()
            .onChange(of: activeId) { _, newId in
                withAnimation(.easeOut(duration: AppTheme.Anim.transition)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onChange(of: scrollRequest) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

extension TabStrip where Trailing == EmptyView {
    init(items: [Item], activeId: String, scrollRequest: String? = nil, @ViewBuilder tab: @escaping (Item) -> Tab) {
        self.init(items: items, activeId: activeId, scrollRequest: scrollRequest, tab: tab, trailing: { EmptyView() })
    }
}

struct TabCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
        }
        .buttonStyle(.plain)
    }
}
