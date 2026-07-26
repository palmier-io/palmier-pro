import SwiftUI

struct CapsuleButtonStyle: ButtonStyle {
    enum Variant { case secondary, prominent }
    enum Size { case small, regular }

    var variant: Variant = .secondary
    var size: Size = .small
    var fill: AnyShapeStyle?

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, variant: variant, size: size, fill: fill)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        let size: Size
        let fill: AnyShapeStyle?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        private var fontSize: CGFloat { size == .small ? AppTheme.FontSize.xs : AppTheme.FontSize.smMd }
        private var hPadding: CGFloat { size == .small ? AppTheme.Spacing.smMd : AppTheme.Spacing.lgXl }
        private var vPadding: CGFloat { size == .small ? AppTheme.Spacing.xs : AppTheme.Spacing.smMd }

        private var foreground: AnyShapeStyle {
            guard isEnabled else { return AnyShapeStyle(AppTheme.Text.mutedColor) }
            return variant == .prominent
                ? AnyShapeStyle(AppTheme.Background.baseColor)
                : AnyShapeStyle(AppTheme.Text.secondaryColor)
        }
        private var background: AnyShapeStyle {
            guard isEnabled else { return AnyShapeStyle(AppTheme.Background.raisedColor) }
            if let fill { return fill }
            return variant == .prominent
                ? AnyShapeStyle(AppTheme.Accent.primary)
                : AnyShapeStyle(AppTheme.Background.prominentColor)
        }

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .background(Capsule(style: .continuous).fill(background))
                .overlay(Capsule(style: .continuous).fill(.white.opacity(isEnabled && hovered ? AppTheme.Opacity.faint : 0)))
                .opacity(isEnabled
                    ? (configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
                    : AppTheme.Opacity.strong)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovered = isEnabled && $0 }
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: hovered)
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: isEnabled)
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { .init() }
    static func capsule(_ variant: CapsuleButtonStyle.Variant = .secondary,
                        size: CapsuleButtonStyle.Size = .small,
                        fill: AnyShapeStyle? = nil) -> CapsuleButtonStyle {
        .init(variant: variant, size: size, fill: fill)
    }
}
