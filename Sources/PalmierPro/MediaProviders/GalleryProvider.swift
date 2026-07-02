import Foundation

// Adapter for the two local `serve.mjs` galleries: downloads (:4617 /api/videos) and
// projects (:4618 /api/projects). Both stream files under /media with HTTP Range; only the
// list endpoint and row mapping differ, so `kind` switches the mapping.
struct GalleryProvider: AssetProvider {
    enum Kind: Sendable { case downloads, projects }

    let id: String
    let label: String
    let baseURL: URL
    let listPath: String
    let kind: Kind

    var capabilities: Set<AssetType> { [.video] }

    func fetchURL(forRef ref: String) -> URL? {
        URL(string: ref, relativeTo: baseURL)?.absoluteURL
    }

    func health() async -> Bool {
        guard let url = URL(string: listPath, relativeTo: baseURL) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func list(_ type: AssetType, query: ListQuery) async throws -> ListResult {
        guard type == .video else { return ListResult(items: [], hasMore: false) }
        let rows = try await fetchRows()
        let matched = rows.filter { Self.matches($0, keys: query.keys, kind: kind) }
        let (slice, hasMore) = Self.paginate(matched, page: query.page, limit: query.limit)
        let items = slice.compactMap { mapRow($0) }
        return ListResult(items: items, hasMore: hasMore)
    }

    // MARK: - Fetch

    private func fetchRows() async throws -> [[String: Any]] {
        guard let url = URL(string: listPath, relativeTo: baseURL) else {
            throw AssetProviderError.badResponse(id)
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AssetProviderError.http(id, code) }
        let json = try JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]] { return arr }
        if let obj = json as? [String: Any] {
            for key in ["items", "videos", "projects"] {
                if let arr = obj[key] as? [[String: Any]] { return arr }
            }
        }
        return []
    }

    // MARK: - Mapping

    private func mapRow(_ row: [String: Any]) -> AssetCard? {
        switch kind {
        case .downloads: mapDownloads(row)
        case .projects: mapProjects(row)
        }
    }

    private func mapDownloads(_ row: [String: Any]) -> AssetCard? {
        guard let id = Self.str(row, "id"), let src = Self.str(row, "src") else { return nil }
        let source = Self.str(row, "source")
        let name = Self.str(row, "title") ?? Self.str(row, "author")
            ?? "\(source ?? "video") · \(id)"
        let desc = [source, Self.str(row, "author"), Self.str(row, "resolution")]
            .compactMap { $0 }.joined(separator: " · ")
        return AssetCard(
            id: id, providerId: self.id, type: .video, name: name, ref: src,
            thumbnailRef: Self.str(row, "poster"),
            description: desc.isEmpty ? nil : desc,
            durationMs: Self.dbl(row, "durationSec").map { Int($0 * 1000) },
            aspect: Self.str(row, "cardAspect"),
            isLocal: true
        )
    }

    private func mapProjects(_ row: [String: Any]) -> AssetCard? {
        // Drafts have no `video` → dropped here.
        guard let id = Self.str(row, "id"), let video = Self.str(row, "video") else { return nil }
        let name = Self.str(row, "title") ?? id
        let platforms = (row["publish"] as? [[String: Any]])?.compactMap { Self.str($0, "platform") } ?? []
        let desc = ([Self.str(row, "status"), Self.str(row, "dims"), Self.str(row, "source")] + platforms)
            .compactMap { $0 }.joined(separator: " · ")
        return AssetCard(
            id: id, providerId: self.id, type: .video, name: name, ref: video,
            thumbnailRef: Self.str(row, "cover"),
            description: desc.isEmpty ? nil : desc,
            durationMs: nil,
            aspect: Self.str(row, "ratio").map { $0.replacingOccurrences(of: ":", with: " / ") },
            isLocal: true
        )
    }

    // MARK: - Search / pagination

    // AND-match, case-insensitive substring over the card's searchable text (design §10.3).
    private static func matches(_ row: [String: Any], keys: [String], kind: Kind) -> Bool {
        let keys = keys.filter { !$0.isEmpty }.map { $0.lowercased() }
        guard !keys.isEmpty else { return true }
        let hay = haystack(row, kind: kind).lowercased()
        return keys.allSatisfy { hay.contains($0) }
    }

    private static func haystack(_ row: [String: Any], kind: Kind) -> String {
        var parts: [String?]
        switch kind {
        case .downloads:
            parts = [str(row, "title"), str(row, "author"), str(row, "source"),
                     str(row, "description"), str(row, "url")]
            if let tags = row["tags"] as? [String] { parts.append(tags.joined(separator: " ")) }
        case .projects:
            parts = [str(row, "title"), str(row, "id"), str(row, "status"), str(row, "source")]
            if let tags = row["tags"] as? [String] { parts.append(tags.joined(separator: " ")) }
            if let pub = row["publish"] as? [[String: Any]] {
                parts.append(pub.compactMap { str($0, "platform") }.joined(separator: " "))
            }
        }
        return parts.compactMap { $0 }.joined(separator: " ")
    }

    private static func paginate<T>(_ arr: [T], page: Int, limit: Int) -> (slice: [T], hasMore: Bool) {
        let limit = max(1, limit)
        let start = max(0, (page - 1) * limit)
        guard start < arr.count else { return ([], false) }
        let end = min(start + limit, arr.count)
        return (Array(arr[start..<end]), end < arr.count)
    }

    // MARK: - Field readers

    private static func str(_ row: [String: Any], _ key: String) -> String? {
        guard let s = row[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func dbl(_ row: [String: Any], _ key: String) -> Double? {
        if let n = row[key] as? NSNumber { return n.doubleValue }
        return row[key] as? Double
    }
}

extension GalleryProvider {
    // Test hooks — mapping and filtering are pure, verified against captured rows.
    func mapRowsForTesting(_ rows: [[String: Any]]) -> [AssetCard] { rows.compactMap(mapRow) }
    func filterForTesting(_ rows: [[String: Any]], keys: [String]) -> [[String: Any]] {
        rows.filter { Self.matches($0, keys: keys, kind: kind) }
    }
}
