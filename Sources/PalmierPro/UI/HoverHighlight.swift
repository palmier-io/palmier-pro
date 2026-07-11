import SwiftUI

struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.Radius.sm
    var isActive: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovered = isEnabled && $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isActive)
    }

    private var fill: Color {
        guard isEnabled else { return .clear }
        return switch (isActive, isHovered) {
        case (true, true): Color.white.opacity(AppTheme.Opacity.muted)
        case (true, false): Color.white.opacity(AppTheme.Opacity.soft)
        case (false, true): Color.white.opacity(AppTheme.Opacity.faint)
        case (false, false): .clear
        }
    }
}

extension View {
    func hoverHighlight(
        cornerRadius: CGFloat = AppTheme.Radius.sm,
        isActive: Bool = false
    ) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isActive: isActive))
    }
}
