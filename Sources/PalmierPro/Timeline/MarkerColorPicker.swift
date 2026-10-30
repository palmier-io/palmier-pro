import SwiftUI

struct MarkerColorPicker: View {
    let selection: TextStyle.RGBA
    let onSelect: (TextStyle.RGBA) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ForEach(AppTheme.TimelineMarker.presetColors, id: \.self) { preset in
                Button { onSelect(preset) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .stroke(
                                selection == preset
                                    ? AppTheme.Text.primaryColor
                                    : .clear,
                                lineWidth: AppTheme.BorderWidth.medium
                            )
                        TimelineMarkerShape()
                            .fill(preset.swiftUIColor)
                            .padding(AppTheme.Spacing.xxs)
                    }
                    .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: preset.hexString))
                .accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
    }
}
