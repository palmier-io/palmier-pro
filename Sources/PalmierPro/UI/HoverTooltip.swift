import SwiftUI

private struct HoverTooltip: ViewModifier {
    let text: String
    let alignment: Alignment
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isHovering {
                    Text(verbatim: text)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .frame(height: AppTheme.IconSize.lg)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.Background.prominentColor)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    AppTheme.Border.primaryColor,
                                    lineWidth: AppTheme.BorderWidth.thin
                                )
                        }
                        .shadow(AppTheme.Shadow.sm)
                        .offset(y: AppTheme.IconSize.lg + AppTheme.Spacing.xs)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovering)
            .accessibilityLabel(Text(verbatim: text))
    }
}

extension View {
    func hoverTooltip(_ text: String, alignment: Alignment = .bottom) -> some View {
        modifier(HoverTooltip(text: text, alignment: alignment))
    }
}
