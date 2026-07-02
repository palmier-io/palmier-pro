import Foundation

// External media source browsing (§ external-media-providers). These map 1:1 onto the
// AssetProvider contract; import_source_asset routes through the shared loopback-import path.
extension ToolExecutor {

    func runSourcesTool(_ tool: ToolName, _ args: [String: Any]) async -> ToolResult {
        do {
            switch tool {
            case .listSources:      return try await listSources()
            case .listSourceAssets: return try await listSourceAssets(args)
            default:                return .error("Not a sources tool: \(tool.rawValue)")
            }
        } catch let err as ToolError {
            return .error(err.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func listSources() async throws -> ToolResult {
        let providers = AssetProviderRegistry.providers
        let health = await withTaskGroup(of: (String, Bool).self) { group in
            for p in providers { group.addTask { (p.id, await p.health()) } }
            var out: [String: Bool] = [:]
            for await (id, ok) in group { out[id] = ok }
            return out
        }
        let rows = providers.map { p -> [String: Any] in
            [
                "id": p.id,
                "label": p.label,
                "capabilities": p.capabilities.map(\.rawValue).sorted(),
                "online": health[p.id] ?? false,
            ]
        }
        return .ok(Self.jsonString(["sources": rows]) ?? "{}")
    }

    private static let listSourceAssetsAllowedKeys: Set<String> =
        ["provider", "type", "keys", "page", "limit"]

    private func listSourceAssets(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.listSourceAssetsAllowedKeys, path: "list_source_assets")
        guard let providerId = args.string("provider") else {
            throw ToolError("list_source_assets requires 'provider'. Call list_sources.")
        }
        guard let provider = AssetProviderRegistry.provider(providerId) else {
            throw ToolError("Unknown provider '\(providerId)'. Call list_sources.")
        }

        let type: AssetType
        if let raw = args.string("type") {
            guard let t = AssetType(rawValue: raw) else {
                throw ToolError("Unknown type '\(raw)'. One of: \(AssetType.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            type = t
        } else if let only = provider.capabilities.count == 1 ? provider.capabilities.first : nil {
            type = only
        } else {
            throw ToolError("Provider '\(providerId)' supports multiple types; set 'type'.")
        }
        guard provider.capabilities.contains(type) else {
            throw ToolError("Provider '\(providerId)' does not support '\(type.rawValue)'.")
        }

        var query = ListQuery()
        query.keys = args.stringArray("keys")
        query.page = max(1, args.int("page") ?? 1)
        query.limit = min(100, max(1, args.int("limit") ?? 30))

        let result: ListResult
        do {
            result = try await provider.list(type, query: query)
        } catch {
            throw ToolError("Source '\(providerId)' unavailable: \(error.localizedDescription) Is its server running?")
        }

        let items = result.items.map { c -> [String: Any] in
            var row: [String: Any] = ["id": c.id, "name": c.name, "ref": c.ref, "type": c.type.rawValue]
            if let d = c.durationMs { row["durationMs"] = d }
            if let s = c.description { row["description"] = s }
            if !c.isLocal { row["local"] = false }
            return row
        }
        var payload: [String: Any] = ["provider": providerId, "items": items, "hasMore": result.hasMore]
        if result.items.contains(where: { !$0.isLocal }) {
            payload["note"] = "Items with local:false aren't downloaded yet — import_source_asset will fail until they're fetched in the source app."
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private static let importSourceAssetAllowedKeys: Set<String> =
        ["provider", "ref", "name", "folderId", "type"]

    func importSourceAsset(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importSourceAssetAllowedKeys, path: "import_source_asset")
        guard let providerId = args.string("provider") else {
            throw ToolError("import_source_asset requires 'provider'.")
        }
        guard let ref = args.string("ref") else {
            throw ToolError("import_source_asset requires 'ref' (from list_source_assets).")
        }
        let typeHint = args.string("type").flatMap(AssetType.init(rawValue:))
        return try importFromProvider(
            editor: editor, providerId: providerId, ref: ref,
            name: args.string("name"), folderId: args.string("folderId"), typeHint: typeHint
        )
    }
}
