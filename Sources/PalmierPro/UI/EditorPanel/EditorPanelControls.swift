import SwiftUI

private struct EditorValueFieldModifier: ViewModifier {
    var active = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(minHeight: AppTheme.EditorPanel.fieldMinHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm, style: .continuous)
                    .fill(AppTheme.Background.baseColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm, style: .continuous)
                    .strokeBorder(border, lineWidth: AppTheme.BorderWidth.thin)
            )
            .opacity(isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
    }

    private var border: Color {
        if active { return AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) }
        if isHovered && isEnabled { return AppTheme.Border.primaryColor }
        return AppTheme.Border.subtleColor
    }
}

extension View {
    func editorValueField(active: Bool = false) -> some View {
        modifier(EditorValueFieldModifier(active: active))
    }
}

struct EditorMenuValue: View {
    let text: String
    var expanded = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.xs)
            Image(systemName: "chevron.down")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .frame(maxWidth: expanded ? .infinity : nil)
        .editorValueField()
    }
}

struct EditorPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Background.baseColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Accent.primary)
            )
            .opacity(isEnabled ? (configuration.isPressed ? AppTheme.Opacity.high : AppTheme.Opacity.opaque) : AppTheme.Opacity.medium)
    }
}

extension ButtonStyle where Self == EditorPrimaryButtonStyle {
    static var editorPrimary: EditorPrimaryButtonStyle { EditorPrimaryButtonStyle() }
}
