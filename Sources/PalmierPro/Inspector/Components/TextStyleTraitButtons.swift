import SwiftUI

struct TextStyleTraitButtons: View {
    let isBold: Bool?
    let isItalic: Bool?
    let isUnderlined: Bool?
    let isStruckThrough: Bool?
    let isOverlined: Bool?
    let onBold: (Bool) -> Void
    let onItalic: (Bool) -> Void
    let onUnderline: (Bool) -> Void
    let onStrikethrough: (Bool) -> Void
    let onOverline: (Bool) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            traitButton(
                systemName: "bold",
                label: "Bold",
                state: isBold,
                action: { onBold(!(isBold ?? false)) }
            )
            traitButton(
                systemName: "italic",
                label: "Italic",
                state: isItalic,
                action: { onItalic(!(isItalic ?? false)) }
            )
            traitButton(systemName: "underline", label: "Underline", state: isUnderlined) {
                onUnderline(!(isUnderlined ?? false))
            }
            traitButton(systemName: "strikethrough", label: "Strikethrough", state: isStruckThrough) {
                onStrikethrough(!(isStruckThrough ?? false))
            }
            traitButton(systemName: "textformat", label: "Overline", state: isOverlined, overline: true) {
                onOverline(!(isOverlined ?? false))
            }
        }
    }

    private func traitButton(
        systemName: String,
        label: String,
        state: Bool?,
        overline: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isActive = state == true
        let isMixed = state == nil
        return Button(action: action) {
            Image(systemName: isMixed ? "minus" : systemName)
                .overlay(alignment: .top) {
                    if overline, !isMixed {
                        Rectangle().frame(width: AppTheme.IconSize.xxs, height: AppTheme.BorderWidth.thin)
                    }
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(isActive ? AppTheme.Background.baseColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.md)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm)
                        .fill(isActive ? AppTheme.Accent.primary : Color.white.opacity(AppTheme.Opacity.hint))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm)
                        .strokeBorder(
                            isActive ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                            lineWidth: isActive ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                        )
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
