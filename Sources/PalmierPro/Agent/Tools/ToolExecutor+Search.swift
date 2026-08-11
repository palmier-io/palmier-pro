import Foundation

extension ToolExecutor {
    private static let searchMediaAllowedKeys: Set<String> = ["query", "scope", "mediaRef", "limit"]

    func searchMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.searchMediaAllowedKeys, path: "search_media")
        let query = try args.requireString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError("search_media: query is empty") }
        let scope = args.string("scope") ?? "both"
        guard ["visual", "spoken", "both"].contains(scope) else {
            throw ToolError("search_media: scope must be visual, spoken, or both (got '\(scope)')")
        }
        let limit = min(max(args.int("limit") ?? 10, 1), 50)
        var restrict: Set<String>?
        if let ref = args.string("mediaRef") {
            restrict = [try asset(ref, editor: editor).id]
        }

        var payload: [String: Any] = ["timelineFps": editor.timeline.fps]
        if scope != "spoken" {
            let (moments, index) = await visualResults(editor, query: query, limit: limit, restrict: restrict)
            payload["moments"] = moments
            if let index { payload["index"] = index }
        }
        if scope != "visual" {
            payload["spoken"] = await spokenResults(editor, query: query, limit: limit, restrict: restrict)
        }

        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("search_media: failed to encode results")
        }
        return .ok(json)
    }

    /// Index health rides along only while it can explain missing results.
    private func visualResults(
        _ editor: EditorViewModel, query: String, limit: Int, restrict: Set<String>?
    ) async -> (moments: [[String: Any]], index: [String: Any]?) {
        let coordinator = editor.searchIndex
        if VisualModelLoader.shared.enabled, VisualModelLoader.shared.state == .unknown {
            await VisualModelLoader.shared.prepare()
        }

        let status = Self.visualStatus(coordinator)
        let indexable = editor.mediaAssets.filter {
            ($0.type == .video || $0.type == .image) && (restrict?.contains($0.id) ?? true)
        }
        var indexed: Int?
        if let spec = VisualModelLoader.shared.embedder?.spec {
            let urls = indexable.map(\.url)
            indexed = await Task.detached {
                urls.filter { !VisualIndexer.needsIndex(url: $0, spec: spec) }.count
            }.value
        }

        var index: [String: Any]?
        if status != "ready" || (indexed ?? indexable.count) < indexable.count {
            var info: [String: Any] = ["status": status, "indexableAssets": indexable.count]
            if let indexed { info["indexedAssets"] = indexed }
            index = info
        }

        let hits = await coordinator.search(query: query, limit: limit, within: restrict)
        let moments = hits.map { hit -> [String: Any] in
            let asset = editor.mediaAssets.first { $0.id == hit.assetID }
            var entry: [String: Any] = [
                "mediaRef": hit.assetID,
                "name": asset?.name ?? "",
                "score": Double(hit.score),
            ]
            if asset?.type == .image {
                entry["type"] = "image"
            } else {
                entry["startSeconds"] = hit.shotStart
                entry["endSeconds"] = hit.shotEnd
            }
            return entry
        }
        return (moments, index)
    }

    private func spokenResults(
        _ editor: EditorViewModel, query: String, limit: Int, restrict: Set<String>?
    ) async -> [[String: Any]] {
        let candidates = editor.mediaAssets
            .filter { ($0.type == .video || $0.type == .audio) && (restrict?.contains($0.id) ?? true) }
            .map { (id: $0.id, url: $0.url) }
        let hits = TranscriptSearch.search(query: query, assets: candidates, limit: limit)
        return hits.map { hit in
            [
                "mediaRef": hit.assetID,
                "name": editor.mediaAssets.first { $0.id == hit.assetID }?.name ?? "",
                "startSeconds": hit.start,
                "endSeconds": hit.end,
                "text": hit.text,
            ]
        }
    }

    private static func visualStatus(_ coordinator: SearchIndexCoordinator) -> String {
        guard VisualModelLoader.shared.enabled else { return "disabled" }
        switch VisualModelLoader.shared.state {
        case .ready: return coordinator.indexingActive ? "indexing" : "ready"
        case .notInstalled: return "modelNotInstalled"
        case .downloading: return "downloadingModel"
        case .preparing, .unknown: return "preparing"
        case .failed: return "failed"
        }
    }
}
