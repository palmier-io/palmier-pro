import SwiftUI

struct ApiKeyField: View {
    let label: String
    let placeholder: String
    let hasKey: Bool
    let maskedKey: String
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .medium))
                Text(label)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(hasKey ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if hasKey {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(maskedKey)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                        isShown = false
                    } label: {
                        Image(systemName: "trash").font(.system(size: AppTheme.FontSize.xs))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(hasKey ? "Replace API key" : placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .controlSize(.small)
                    .onSubmit(commit)
                Button("Save", action: commit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 340)
    }

    private func commit() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        onSave(key)
        draft = ""
        isShown = false
    }
}
