import SwiftUI

/// Adds a subtle rounded-rect background that appears on hover and expands the
/// hit area to the framed rect (via `contentShape`). Use on small icon buttons
/// so users can see what's clickable and land on it without aiming at a tiny
/// glyph.
///
/// Apply after the frame has been set on the label:
///
///     Image(systemName: "xmark")
///         .frame(width: 24, height: 24)
///         .hoverHighlight()
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.Radius.sm
    var isActive: Bool = false

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isActive)
    }

    private var fill: Color {
        switch (isActive, isHovered) {
        case (true, true): Color.white.opacity(0.13)
        case (true, false): Color.white.opacity(0.10)
        case (false, true): Color.white.opacity(0.07)
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
