import SwiftUI

struct TabStrip<Item: Identifiable, Tab: View, Trailing: View>: View where Item.ID == String {
    let items: [Item]
    let activeId: String
    var scrollRequest: String? = nil
    var leadingPadding: CGFloat = AppTheme.Spacing.sm
    @ViewBuilder let tab: (Item) -> Tab
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(items) { item in
                        tab(item).id(item.id)
                    }
                    trailing()
                }
                .padding(.leading, leadingPadding)
                .padding(.trailing, AppTheme.Spacing.sm)
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

extension View {
    func documentTabChrome(
        isActive: Bool,
        isCloseable: Bool = false,
        onClose: (() -> Void)? = nil
    ) -> some View {
        modifier(DocumentTabChrome(isActive: isActive, isCloseable: isCloseable, onClose: onClose))
    }
}

private struct DocumentTabChrome: ViewModifier {
    let isActive: Bool
    let isCloseable: Bool
    let onClose: (() -> Void)?
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, AppTheme.Spacing.mdLg)
            .padding(.trailing, isCloseable ? AppTheme.Spacing.xlXxl : AppTheme.Spacing.mdLg)
            .frame(height: AppTheme.IconSize.md)
            .fixedSize(horizontal: true, vertical: false)
            .hoverHighlight(cornerRadius: AppTheme.Radius.xl, isActive: isActive)
            .overlay(alignment: .trailing) {
                if isCloseable, let onClose {
                    TabCloseButton(action: onClose)
                        .padding(.trailing, AppTheme.Spacing.xs)
                        .opacity(isHovered ? AppTheme.Opacity.opaque : AppTheme.Opacity.transparent)
                        .allowsHitTesting(isHovered)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .modifier(DocumentTabCloseAccess(isCloseable: isCloseable, onClose: onClose))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isActive)
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}

private struct DocumentTabCloseAccess: ViewModifier {
    let isCloseable: Bool
    let onClose: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCloseable, let onClose {
            content.accessibilityAction(named: Text(L10n.string("Close Tab")), onClose)
        } else {
            content
        }
    }
}
