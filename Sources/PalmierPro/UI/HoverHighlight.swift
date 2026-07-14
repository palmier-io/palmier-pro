import SwiftUI

struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.Radius.sm
    var isActive: Bool = false
    var activeFill: Color?

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
        if isActive, let activeFill { return activeFill }
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
        isActive: Bool = false,
        activeFill: Color? = nil
    ) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isActive: isActive, activeFill: activeFill))
    }

    func themedSurface(
        _ fill: Color,
        cornerRadius: CGFloat,
        border: Color = AppTheme.Border.subtleColor,
        borderWidth: CGFloat = AppTheme.BorderWidth.thin
    ) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
    }
}
