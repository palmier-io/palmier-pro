import Foundation

/// Populates ModelCatalog from the gateway when the hosted backend isn't
/// configured (GENERATION_GATEWAY_PLAN.md Phase 2). Capabilities come from a
/// bundled template — the gateway's /model/info confirms which aliases exist
/// and carries no caps of its own. Video entries are included regardless of
/// /model/info: the video bridge lives beside the gateway, not in its model
/// list (GATEWAY_CONTRACT.md).
@MainActor
enum GatewayCatalog {
    private static var installed = false

    static func install(into catalog: ModelCatalog) {
        Task { await populate(catalog) }
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: .openAICompatGatewayChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await populate(catalog) }
        }
    }

    private static func populate(_ catalog: ModelCatalog) async {
        guard OpenAICompatGenerationClient.gatewayConfigured,
              let client = OpenAICompatGenerationClient.fromGateway() else { return }
        do {
            let available = Set(try await client.listModels().map(\.id))
            let entries = try entries(fromTemplate: templateData(), availableAliases: available)
            catalog.applyGatewayEntries(entries)
            Log.generation.notice("gateway catalog installed: \(entries.count) models")
        } catch {
            Log.generation.error("gateway catalog load failed: \(error.localizedDescription)")
        }
    }

    static func templateData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "gateway-models", withExtension: "json", subdirectory: "GatewayCatalog"
        ) else {
            throw OpenAICompatGenerationError.api("bundled gateway catalog missing")
        }
        return try Data(contentsOf: url)
    }

    /// Pure + testable: keep image templates whose alias the gateway actually
    /// serves (remapped through the user's alias overrides); keep video
    /// templates unconditionally (served by the bridge, invisible to /model/info).
    static func entries(fromTemplate data: Data, availableAliases: Set<String>) throws -> [CatalogEntry] {
        guard var raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenAICompatGenerationError.decodeFailed
        }
        let overrides = aliasOverrides()
        raw = raw.compactMap { entry in
            guard let id = entry["id"] as? String, let kind = entry["kind"] as? String else { return nil }
            var entry = entry
            let resolved = overrides[id] ?? id
            entry["id"] = resolved
            if kind == "video" { return entry }
            return availableAliases.contains(resolved) ? entry : nil
        }
        let patched = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([CatalogEntry].self, from: patched)
    }

    /// fallback-alias → user-overridden alias, for the generation-capable slots.
    @MainActor
    static func aliasOverrides() -> [String: String] {
        var map: [String: String] = [:]
        for alias in [GatewayImageModels.gen, GatewayImageModels.turbo, GatewayImageModels.typography] {
            let resolved = GatewayImageModels.resolve(alias)
            if resolved != alias.fallback { map[alias.fallback] = resolved }
        }
        let video = GatewayVideoModels.resolve(GatewayVideoModels.gen)
        if video != GatewayVideoModels.gen.fallback { map[GatewayVideoModels.gen.fallback] = video }
        return map
    }
}

/// Gateway alias for the video bridge (GATEWAY_CONTRACT.md video section).
enum GatewayVideoModels {
    static let gen = GatewayImageModels.Alias(
        key: "gatewayVideoGenModel", label: "Text/image-to-video", fallback: "protolabs/ltx2-video"
    )

    static func resolve(_ alias: GatewayImageModels.Alias) -> String {
        let saved = UserDefaults.standard.string(forKey: alias.key) ?? ""
        return saved.isEmpty ? alias.fallback : saved
    }
}

/// Gateway alias for ACE-Step music (GATEWAY_CONTRACT.md audio section).
enum GatewayAudioModels {
    static let gen = GatewayImageModels.Alias(
        key: "gatewayAudioGenModel", label: "Music generation", fallback: "protolabs/ace-step"
    )

    static func resolve(_ alias: GatewayImageModels.Alias) -> String {
        let saved = UserDefaults.standard.string(forKey: alias.key) ?? ""
        return saved.isEmpty ? alias.fallback : saved
    }
}
