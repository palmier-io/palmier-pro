import SwiftUI

struct InspectorSlider: View {
    let icon: String
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let displayMultiplier: Double
    let valueSuffix: String
    let format: String
    var displayTextOverride: ((Double) -> String?)? = nil
    var onChanged: ((Double) -> Void)? = nil
    let onCommit: (Double) -> Void

    @State private var liveValue: Double = 0
    @State private var isDragging = false

    private var displayValue: Double { (isDragging ? liveValue : value) * displayMultiplier }

    private var displayText: String {
        let raw = isDragging ? liveValue : value
        if let override = displayTextOverride?(raw) { return override }
        return String(format: format, displayValue) + valueSuffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Text(displayText)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }

            Slider(value: $liveValue, in: range) { editing in
                if editing {
                    isDragging = true
                } else {
                    isDragging = false
                    onCommit(liveValue)
                }
            }
            .controlSize(.small)
            .tint(Color.white.opacity(0.5))
        }
        .onAppear { liveValue = value }
        .onChange(of: value) { _, newValue in
            if !isDragging { liveValue = newValue }
        }
        .onChange(of: liveValue) { _, newValue in
            if isDragging { onChanged?(newValue) }
        }
    }
}
