import SwiftUI

/// Lets the user unlock keyed stock sources. The Creative Commons sources need no key, so these
/// are the only credentials behind `find_stock_media`.
struct StockMediaKeySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            ProviderAPIKeyField(provider: .pexels)
            Divider()
            ProviderAPIKeyField(provider: .pixabay)
        }
    }
}

private struct ProviderAPIKeyField: View {
    enum Provider: Sendable {
        case pexels
        case pixabay

        var titleKey: String {
            switch self {
            case .pexels: "Pexels API key"
            case .pixabay: "Pixabay API key"
            }
        }

        var detailsKey: String {
            switch self {
            case .pexels:
                "Free key for accounts that already hold one. Unlocks Pexels stock video and photography for the agent. Creative Commons image and sound search works without it."
            case .pixabay:
                "Free key from pixabay.com/api/docs. Unlocks Pixabay stock video search for the agent. Creative Commons image and sound search works without it."
            }
        }

        var availabilityKey: String {
            switch self {
            case .pexels: "Pexels video search is available."
            case .pixabay: "Pixabay video search is available."
            }
        }

        func readKey() async -> String {
            switch self {
            case .pexels: await StockMediaCredentials.pexelsKey()
            case .pixabay: await StockMediaCredentials.pixabayKey()
            }
        }

        func writeKey(_ key: String?) async {
            switch self {
            case .pexels: await StockMediaCredentials.setPexelsKey(key)
            case .pixabay: await StockMediaCredentials.setPixabayKey(key)
            }
        }
    }

    let provider: Provider
    @State private var key = ""
    @State private var hasKey = false
    @State private var isLoaded = false

    private var isDirty: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string(key: provider.titleKey))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text(L10n.string(key: provider.detailsKey))
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
                    .accessibilityLabel(L10n.string(key: provider.titleKey))

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
                Text(L10n.string(key: provider.availabilityKey))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .task {
            guard !isLoaded else { return }
            hasKey = !(await provider.readKey()).isEmpty
            isLoaded = true
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await provider.writeKey(trimmed)
            key = ""
            hasKey = true
        }
    }

    private func remove() {
        Task {
            await provider.writeKey(nil)
            key = ""
            hasKey = false
        }
    }
}
