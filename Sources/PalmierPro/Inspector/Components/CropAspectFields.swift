import AppKit
import SwiftUI

struct CropAspectFields: View {
    let ratio: CropAspectRatio
    let onCommit: (CropAspectRatio) -> Void

    @State private var horizontal: Double
    @State private var vertical: Double
    @State private var cancelling = false
    @FocusState private var focusedField: Field?

    init(
        ratio: CropAspectRatio,
        onCommit: @escaping (CropAspectRatio) -> Void
    ) {
        self.ratio = ratio
        self.onCommit = onCommit
        _horizontal = State(initialValue: ratio.horizontal)
        _vertical = State(initialValue: ratio.vertical)
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ratioField("Width", value: $horizontal, field: .horizontal, alignment: .trailing)
            Text(verbatim: ":")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ratioField("Height", value: $vertical, field: .vertical, alignment: .leading)
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .editorValueField(active: focusedField != nil)
        .fixedSize()
        .help(L10n.string("Choose a crop aspect"))
        .onChange(of: ratio) { _, newRatio in
            guard focusedField == nil else { return }
            updateValues(from: newRatio)
        }
        .onChange(of: focusedField) { oldField, newField in
            guard oldField != nil, newField == nil else { return }
            if cancelling {
                cancelling = false
            } else {
                commitInput()
            }
        }
    }

    private func ratioField(
        _ label: String,
        value: Binding<Double>,
        field: Field,
        alignment: TextAlignment
    ) -> some View {
        TextField(
            String(),
            value: value,
            format: .number.grouping(.never).precision(.fractionLength(0...4))
        )
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium).monospacedDigit())
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(width: AppTheme.EditorPanel.compactNumericFieldWidth, height: AppTheme.EditorPanel.fieldMinHeight)
            .focused($focusedField, equals: field)
            .onSubmit { focusedField = nil }
            .onExitCommand {
                updateValues(from: ratio)
                cancelling = true
                focusedField = nil
            }
            .accessibilityLabel(L10n.string("Aspect ratio: \(label)"))
    }

    private func commitInput() {
        guard let newRatio = CropAspectRatio(horizontal: horizontal, vertical: vertical) else {
            NSSound.beep()
            updateValues(from: ratio)
            return
        }
        guard newRatio != ratio else { return }
        onCommit(newRatio)
    }

    private func updateValues(from ratio: CropAspectRatio) {
        horizontal = ratio.horizontal
        vertical = ratio.vertical
    }

    private enum Field: Hashable { case horizontal, vertical }
}
