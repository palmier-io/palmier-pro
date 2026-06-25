import SwiftUI

struct ColorWheelControl: View {
    let title: String
    let x: Double
    let y: Double
    let master: Double
    let masterRange: ClosedRange<Double>
    let masterDefault: Double
    let onColorChanged: (Double, Double) -> Void
    let onColorCommit: (Double, Double) -> Void
    let onMasterChanged: (Double) -> Void
    let onMasterCommit: (Double) -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            ColorWheelPad(x: x, y: y, onChanged: onColorChanged, onCommit: onColorCommit)
            AdjustSlider(
                value: master,
                range: masterRange,
                gradient: AppTheme.Slider.lumaGradient,
                defaultValue: masterDefault,
                onChanged: onMasterChanged,
                onCommit: onMasterCommit
            )
            .frame(width: AppTheme.Wheels.padSize)
        }
    }
}
