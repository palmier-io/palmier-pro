import SwiftUI

struct TimelineColorsPane: View {
    @Bindable private var colors = TimelineClipColorStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(spacing: 0) {
                ForEach(Array(TimelineClipColor.allCases.enumerated()), id: \.element) { index, kind in
                    colorRow(kind)

                    if index < TimelineClipColor.allCases.count - 1 {
                        Rectangle()
                            .fill(AppTheme.Border.subtleColor)
                            .frame(height: AppTheme.BorderWidth.hairline)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reset All") {
                    colors.resetAll()
                }
                .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))
                .disabled(!colors.hasOverrides)
            }
        }
    }

    private func colorRow(_ kind: TimelineClipColor) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(kind.label)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Spacer(minLength: AppTheme.Spacing.md)

            Text(colors.hex(for: kind))
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            ColorField(
                displayColor: colors.color(for: kind),
                onUserChange: { colors.set($0, for: kind) },
                supportsOpacity: false,
                accessibilityLabel: "Choose \(kind.label.lowercased()) clip color",
                swatchSize: CGSize(width: 64, height: AppTheme.IconSize.mdLg)
            )
        }
        .frame(minHeight: 36)
    }
}
