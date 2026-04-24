import SwiftUI

struct InspectorNumberField: View {
    let label: String
    let value: Double
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm).monospacedDigit())
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(0.06))
                )
                .focused($isFocused)
                .onSubmit { commitValue() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitValue() }
                }
        }
        .onAppear { text = String(Int(value.rounded())) }
        .onChange(of: value) { _, newValue in
            if !isFocused { text = String(Int(newValue.rounded())) }
        }
    }

    private func commitValue() {
        if let parsed = Double(text) {
            onCommit(parsed)
        } else {
            text = String(Int(value.rounded()))
        }
    }
}
