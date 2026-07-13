import Foundation
import SwiftUI

/// Gateway aliases for the protoBanana image suite. Aliases are configuration,
/// not code (GATEWAY_CONTRACT.md) — each maps to a `model_list` entry on the
/// gateway; defaults match the protolabs deployment.
enum GatewayImageModels {
    struct Alias: Identifiable {
        let key: String
        let label: String
        let fallback: String
        var id: String { key }
    }

    static let gen = Alias(key: "gatewayImageGenModel", label: "Text-to-image", fallback: "protolabs/qwen-image")
    static let turbo = Alias(key: "gatewayImageTurboModel", label: "Draft (fast)", fallback: "protolabs/qwen-image-turbo")
    static let edit = Alias(key: "gatewayImageEditModel", label: "Edit", fallback: "protolabs/qwen-image-edit")
    static let region = Alias(key: "gatewayImageRegionModel", label: "Region edit", fallback: "protolabs/qwen-image-region-edit")
    static let bgremove = Alias(key: "gatewayImageBgremoveModel", label: "Background removal", fallback: "protolabs/qwen-image-bgremove")
    static let outpaint = Alias(key: "gatewayImageOutpaintModel", label: "Outpaint", fallback: "protolabs/qwen-image-outpaint")
    static let identity = Alias(key: "gatewayImageIdentityModel", label: "Identity edit", fallback: "protolabs/krea2-identity-edit")
    static let realismIdentity = Alias(key: "gatewayImageRealismIdentityModel", label: "Identity edit (realism)", fallback: "protolabs/krea2-identity-edit-realism")
    static let typography = Alias(key: "gatewayImageTypographyModel", label: "Typography", fallback: "protolabs/ideogram-4")
    static let chat = Alias(key: "gatewayImageChatModel", label: "Compose (chat)", fallback: "protolabs/qwen-image-chat")

    static let all: [Alias] = [gen, turbo, edit, region, bgremove, outpaint, identity, realismIdentity, typography, chat]

    static func resolve(_ alias: Alias) -> String {
        let saved = UserDefaults.standard.string(forKey: alias.key) ?? ""
        return saved.isEmpty ? alias.fallback : saved
    }

    static func save(_ alias: Alias, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == alias.fallback {
            UserDefaults.standard.removeObject(forKey: alias.key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: alias.key)
        }
    }
}

/// Settings UI for the aliases — one row per op, collapsed by default.
struct GatewayImageAliasesSection: View {
    @State private var values: [String: String] = [:]

    private var aliases: [GatewayImageModels.Alias] {
        GatewayImageModels.all + [GatewayVideoModels.gen]
    }

    var body: some View {
        DisclosureGroup {
            VStack(spacing: AppTheme.Spacing.xs) {
                ForEach(aliases) { alias in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(alias.label)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(width: 160, alignment: .trailing)
                        TextField(alias.fallback, text: binding(for: alias))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    }
                }
            }
            .padding(.top, AppTheme.Spacing.xs)
        } label: {
            Text("Generation model aliases")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
        }
        .onAppear {
            for alias in aliases {
                let saved = UserDefaults.standard.string(forKey: alias.key) ?? ""
                values[alias.key] = saved
            }
        }
    }

    private func binding(for alias: GatewayImageModels.Alias) -> Binding<String> {
        Binding(
            get: { values[alias.key] ?? "" },
            set: { newValue in
                values[alias.key] = newValue
                GatewayImageModels.save(alias, value: newValue)
            }
        )
    }
}
