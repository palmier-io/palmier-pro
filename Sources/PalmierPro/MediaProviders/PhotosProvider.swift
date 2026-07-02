import Foundation

// Adapter for photos-bridge (:5374) — the local macOS Photos library. Video via /api/ls +
// /video/<uuid> + /thumb/<uuid>; image via /api/ls-images + /image/<uuid> (HEIC→JPEG) +
// /image-thumb/<uuid>. iCloud-only originals report local=false and can't be imported until
// fetched in photos-bridge. Mirrors orca-vvcut's photos.ts.
//
// Refs are full endpoint paths ("/video/<uuid>") with NO file extension — so import must take
// the type from the card, not the URL (see importFromProvider's typeHint).
struct PhotosProvider: AssetProvider {
    let id = "photos"
    let label = "本地 Photos"
    let baseURL: URL

    var capabilities: Set<AssetType> { [.video, .image] }

    func fetchURL(forRef ref: String) -> URL? {
        URL(string: ref, relativeTo: baseURL)?.absoluteURL
    }

    func health() async -> Bool {
        guard let url = URL(string: "/api/ls?limit=1", relativeTo: baseURL) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func list(_ type: AssetType, query: ListQuery) async throws -> ListResult {
        switch type {
        case .video: try await listMedia(path: "/api/ls", type: .video,
                                         fileBase: "/video/", thumbBase: "/thumb/", query: query)
        case .image: try await listMedia(path: "/api/ls-images", type: .image,
                                         fileBase: "/image/", thumbBase: "/image-thumb/", query: query)
        case .music, .sfx: ListResult(items: [], hasMore: false)
        }
    }

    // /api/ls has no offset — fetch a batch (server-side keyword) then paginate client-side.
    private func listMedia(path: String, type: AssetType, fileBase: String, thumbBase: String,
                           query: ListQuery) async throws -> ListResult {
        var comps = URLComponents(url: baseURL.appendingPathComponent(String(path.dropFirst())),
                                  resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: "500")]
        let keywords = query.keys.filter { !$0.isEmpty }
        if !keywords.isEmpty { items.append(URLQueryItem(name: "keyword", value: keywords.joined(separator: " "))) }
        comps?.queryItems = items
        guard let url = comps?.url else { throw AssetProviderError.badResponse(id) }

        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AssetProviderError.http(id, code) }
        let rows = Self.extractRows(try JSONSerialization.jsonObject(with: data))

        let (slice, more) = Self.paginate(rows, page: query.page, limit: query.limit)
        let cards = slice.compactMap { card(from: $0, type: type, fileBase: fileBase, thumbBase: thumbBase) }
        return ListResult(items: cards, hasMore: more)
    }

    func card(from row: [String: Any], type: AssetType, fileBase: String, thumbBase: String) -> AssetCard? {
        guard let uuid = Self.str(row, "id") else { return nil }
        let isLocal = (row["local"] as? Bool) != false
        let desc = [
            Self.dbl(row, "durationSec").map { "\(Int($0.rounded()))s" },
            (row["isLivePhoto"] as? Bool) == true ? "LIVE" : nil,
            Self.str(row, "orientation"),
            isLocal ? nil : "iCloud",
        ].compactMap { $0 }.joined(separator: " · ")
        return AssetCard(
            id: uuid, providerId: id, type: type,
            name: Self.str(row, "filename") ?? uuid,
            ref: fileBase + uuid, thumbnailRef: thumbBase + uuid,
            description: desc.isEmpty ? nil : desc,
            durationMs: Self.dbl(row, "durationSec").map { Int($0 * 1000) },
            aspect: nil, isLocal: isLocal
        )
    }

    // photos-bridge wraps its payload: { ok, data: [...] } (or data.clips for video).
    private static func extractRows(_ json: Any) -> [[String: Any]] {
        guard let env = json as? [String: Any] else { return json as? [[String: Any]] ?? [] }
        if (env["ok"] as? Bool) == false { return [] }
        if let arr = env["data"] as? [[String: Any]] { return arr }
        if let data = env["data"] as? [String: Any], let clips = data["clips"] as? [[String: Any]] { return clips }
        return []
    }

    private static func paginate<T>(_ arr: [T], page: Int, limit: Int) -> (slice: [T], hasMore: Bool) {
        let limit = max(1, limit)
        let start = max(0, (page - 1) * limit)
        guard start < arr.count else { return ([], false) }
        let end = min(start + limit, arr.count)
        return (Array(arr[start..<end]), end < arr.count)
    }

    private static func str(_ row: [String: Any], _ key: String) -> String? {
        guard let s = row[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func dbl(_ row: [String: Any], _ key: String) -> Double? {
        if let n = row[key] as? NSNumber { return n.doubleValue }
        return row[key] as? Double
    }
}
