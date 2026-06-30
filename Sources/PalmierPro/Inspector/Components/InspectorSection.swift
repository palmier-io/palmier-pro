import SwiftUI

struct InspectorSection<Content: View>: View {
    let title: String
    private let isExpanded: Binding<Bool>?
    private let contentSpacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(_ title: String, contentSpacing: CGFloat = AppTheme.Spacing.md, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isExpanded = nil
        self.contentSpacing = contentSpacing
        self.content = content
    }

    init(_ title: String, isExpanded: Binding<Bool>, contentSpacing: CGFloat = AppTheme.Spacing.md, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isExpanded = isExpanded
        self.contentSpacing = contentSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header

            if isExpanded?.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: contentSpacing) {
                    content()
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let isExpanded {
            Button {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                    titleText
                    Spacer(minLength: AppTheme.Spacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title.uppercased())
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
    }
}
