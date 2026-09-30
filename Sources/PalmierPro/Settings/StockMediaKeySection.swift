import SwiftUI

/// Lets the user unlock Pexels stock video and photography. The Creative Commons sources need
/// no key, so this is the one credential behind `find_stock_media`.
struct StockMediaKeySection: View {
    @State private var key = ""
    @State private var hasKey = false
    @State private var isLoaded = false

    private var isDirty: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("Pexels API key"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text(L10n.string("Free key from pexels.com/api. Unlocks stock video and photography for the agent. Creative Commons image and sound search works without it."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(hasKey ? L10n.string("Key saved — type to replace") : L10n.string("Paste key"), text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
                    .onSubmit(save)
                    .accessibilityLabel(L10n.string("Pexels API key"))

                Button(L10n.string("Save")) { save() }
                    .buttonStyle(.capsule(.secondary))
                    .disabled(!isDirty)
                    .fixedSize()

                if hasKey {
                    Button(L10n.string("Remove")) { remove() }
                        .buttonStyle(.capsule(.secondary))
                        .fixedSize()
                }
            }

            if hasKey {
                Text(L10n.string("Stock video search is available."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .task {
            guard !isLoaded else { return }
            hasKey = !(await StockMediaCredentials.pexelsKey()).isEmpty
            isLoaded = true
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await StockMediaCredentials.setPexelsKey(trimmed)
            key = ""
            hasKey = true
        }
    }

    private func remove() {
        Task {
            await StockMediaCredentials.setPexelsKey(nil)
            key = ""
            hasKey = false
        }
    }
}
