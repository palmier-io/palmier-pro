import Foundation

extension ToolExecutor {
    fileprivate struct FindStockMediaInput: DecodableToolArgs {
        let query: String
        let kind: String?
        let orientation: String?
        let maxDurationSeconds: Int?
        let limit: Int?
        static let allowedKeys: Set<String> = ["query", "kind", "orientation", "maxDurationSeconds", "limit"]
    }

    /// Searches free, openly-licensed sources for images, audio, and stock video. Returns
    /// candidates only — the download is `import_media`, which already handles staging, byte
    /// caps, and project serialization.
    func findStockMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: FindStockMediaInput = try decodeToolArgs(args, path: "find_stock_media")

        let kind: StockMediaKind
        if let raw = input.kind {
            guard let parsed = StockMediaKind.parse(raw) else {
                throw ToolError("kind must be one of \(StockMediaKind.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')")
            }
            kind = parsed
        } else {
            kind = .image
        }

        if let orientation = input.orientation,
           !["landscape", "portrait", "square"].contains(orientation) {
            throw ToolError("orientation must be landscape, portrait, or square (got '\(orientation)')")
        }
        if let maxDuration = input.maxDurationSeconds, maxDuration < 0 {
            throw ToolError("maxDurationSeconds must be positive (got \(maxDuration))")
        }
        let limit = input.limit ?? 8
        guard (1...20).contains(limit) else {
            throw ToolError("limit must be 1–20 (got \(limit))")
        }

        let request = StockMediaQuery(
            text: input.query,
            kind: kind,
            orientation: input.orientation,
            maxDurationSeconds: input.maxDurationSeconds,
            limit: limit
        )
        let result = try await StockMediaSearch.search(request)

        var notes = [
            "Candidates only — nothing was downloaded. Pass a hit's url to import_media to bring it into the library, then add_clips to place it.",
            "Every hit carries its license and an attribution line. Most of these licenses require crediting the creator, so keep the attribution string with the asset.",
        ]
        if kind == .video {
            notes.append("Stock video comes from Pexels, which needs a free API key in Settings. Without it, video search returns nothing.")
        }
        let unavailable = result.outcomes.filter { $0.status == .needsAPIKey }
        for outcome in unavailable {
            notes.append(outcome.message ?? "\(outcome.id) is not configured.")
        }

        return .ok(Self.jsonString([
            "kind": kind.rawValue,
            "query": request.text,
            "count": result.hits.count,
            "hits": result.hits.map(\.receipt),
            "providers": result.outcomes.map(\.receipt),
            "notes": notes,
        ]) ?? "{}")
    }
}
