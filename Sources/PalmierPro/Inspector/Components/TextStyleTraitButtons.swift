import SwiftUI

struct TextStyleTraitButtons: View {
    let isBold: Bool?
    let isItalic: Bool?
    let onBold: (Bool) -> Void
    let onItalic: (Bool) -> Void

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
        }
    }

    private func traitButton(
        systemName: String,
        label: String,
        state: Bool?,
        action: @escaping () -> Void
    ) -> some View {
        let isActive = state == true
        let isMixed = state == nil
        return Button(action: action) {
            Image(systemName: isMixed ? "minus" : systemName)
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
