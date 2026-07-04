import SwiftUI

/// Commit on Return or blur; Esc cancels. Empty or unchanged input cancels.
struct InlineRenameField: View {
    let originalName: String
    var placeholder: String = ""
    var font: Font = .system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium)
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .font(font)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onExitCommand {
                finished = true
                onCancel()
            }
            .onAppear {
                draft = originalName
                // Same-transaction focus fails to attach; defer one runloop turn.
                DispatchQueue.main.async { focused = true }
            }
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == originalName {
            onCancel()
        } else {
            onCommit(trimmed)
        }
    }
}
