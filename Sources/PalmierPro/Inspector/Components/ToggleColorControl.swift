import SwiftUI

struct ToggleColorControl: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color
    let onColorChange: (Color) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ColorField(displayColor: color, onUserChange: onColorChange)
                .opacity(isOn ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                .disabled(!isOn)
                .accessibilityLabel("\(label) color")

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
                .accessibilityLabel(label)
        }
    }
}
