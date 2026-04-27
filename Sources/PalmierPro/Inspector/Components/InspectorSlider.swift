import SwiftUI

struct InspectorSlider: View {
    let icon: String
    let label: String
    let value: Double?
    let range: ClosedRange<Double>
    let displayMultiplier: Double
    let valueSuffix: String
    let format: String
    var displayTextOverride: ((Double) -> String?)? = nil
    var onChanged: ((Double) -> Void)? = nil
    let onCommit: (Double) -> Void

    @State private var liveValue: Double = 0
    @State private var isDragging = false
    @State private var fieldText: String = ""
    @FocusState private var fieldFocused: Bool

    private var isMixed: Bool { value == nil && !isDragging }
    private var sourceValue: Double { isDragging ? liveValue : (value ?? liveValue) }
    private var displayValue: Double { sourceValue * displayMultiplier }

    private var displayText: String {
        if isMixed { return "—" }
        if let override = displayTextOverride?(sourceValue) { return override }
        return String(format: format, displayValue) + valueSuffix
    }

    private var editingText: String {
        isMixed ? "" : String(format: format, displayValue)
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
                valueField
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
        .onAppear {
            liveValue = value ?? range.lowerBound
            fieldText = displayText
        }
        .onChange(of: value) { _, newValue in
            if !isDragging { liveValue = newValue ?? range.lowerBound }
            if !fieldFocused { fieldText = displayText }
        }
        .onChange(of: liveValue) { _, newValue in
            if isDragging {
                onChanged?(newValue)
                if !fieldFocused { fieldText = displayText }
            }
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging && !fieldFocused { fieldText = displayText }
        }
        .onChange(of: fieldFocused) { _, focused in
            if focused {
                fieldText = editingText
            } else {
                commitEditing()
                fieldText = displayText
            }
        }
    }

    private var valueField: some View {
        TextField("", text: $fieldText)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.primaryColor)
            .focused($fieldFocused)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(fieldFocused ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(fieldFocused ? 0.25 : 0), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.12), value: fieldFocused)
            .onSubmit {
                fieldFocused = false
            }
    }

    private func commitEditing() {
        let trimmed = fieldText.trimmingCharacters(in: .whitespaces)
        let withoutSuffix: String = {
            guard !valueSuffix.isEmpty,
                  trimmed.hasSuffix(valueSuffix) else { return trimmed }
            return String(trimmed.dropLast(valueSuffix.count))
        }()
        let cleaned = withoutSuffix
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(cleaned) else { return }
        let multiplier = displayMultiplier == 0 ? 1 : displayMultiplier
        let raw = parsed / multiplier
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        liveValue = clamped
        onCommit(clamped)
    }
}
