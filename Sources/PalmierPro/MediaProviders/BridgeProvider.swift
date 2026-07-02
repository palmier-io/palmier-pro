import Foundation

// Adapter for the isomorphic 剪映 / CapCut cache bridges (jianying :5174, capcut :5274).
// Both expose /api/cache/music, /api/cache/images, and stream files via /cache-file?p=<rel>.
// Mirrors orca-vvcut's createBridgeProvider (studio/src/lib/providers/bridge.ts).
struct BridgeProvider: AssetProvider {
    let id: String
    let label: String
    let baseURL: URL

    var capabilities: Set<AssetType> { [.music, .sfx, .image] }

    func fetchURL(forRef ref: String) -> URL? {
        var comps = URLComponents(url: baseURL.appendingPathComponent("cache-file"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "p", value: ref)]
        return comps?.url
    }

    func health() async -> Bool {
        guard let url = URL(string: "/api/cache/music", relativeTo: baseURL) else { return false }
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
        switch type {
        case .music, .sfx: try await listAudio(bucket: type, query: query)
        case .image: try await listImage(query: query)
        case .video: ListResult(items: [], hasMore: false)
        }
    }

    // MARK: - Audio (music / sfx share /api/cache/music; kind=='sfx' splits them)

    private func listAudio(bucket: AssetType, query: ListQuery) async throws -> ListResult {
        let rows = try await fetchArray(path: "/api/cache/music", keys: ["tracks", "items"])
        let bucketed = rows.filter { row in
            let isSfx = (row["kind"] as? String) == "sfx"
            return bucket == .sfx ? isSfx : !isSfx
        }
        let matched = bucketed.filter { Self.matches(audioHaystack($0), keys: query.keys) }
        let (slice, more) = Self.paginate(matched, page: query.page, limit: query.limit)
        let items = slice.compactMap { row -> AssetCard? in
            guard let ref = Self.str(row, "sha256") ?? Self.str(row, "rel") else { return nil }
            let fileRef = Self.str(row, "rel") ?? ref
            let name = Self.str(row, "userTitle") ?? Self.str(row, "title")
                ?? Self.str(row, "name") ?? fileRef
            let desc: String?
            if bucket == .sfx, let cats = row["sfxCat"] as? [String], !cats.isEmpty {
                desc = cats.joined(separator: " · ")
            } else {
                desc = Self.str(row, "userAuthor") ?? Self.str(row, "author")
            }
            return AssetCard(
                id: ref, providerId: id, type: bucket, name: name, ref: fileRef,
                thumbnailRef: nil, description: desc,
                durationMs: Self.int(row, "durationMs"), aspect: nil, isLocal: true
            )
        }
        return ListResult(items: items, hasMore: more)
    }

    // MARK: - Image

    private func listImage(query: ListQuery) async throws -> ListResult {
        let rows = try await fetchArray(path: "/api/cache/images", keys: ["images", "items"])
        let matched = rows.filter {
            Self.matches([Self.str($0, "rel"), Self.str($0, "sourceLabel")].compactMap { $0 }.joined(separator: " "),
                         keys: query.keys)
        }
        let (slice, more) = Self.paginate(matched, page: query.page, limit: query.limit)
        let items = slice.compactMap { row -> AssetCard? in
            guard let rel = Self.str(row, "rel") else { return nil }
            return AssetCard(
                id: rel, providerId: id, type: .image,
                name: (rel as NSString).lastPathComponent, ref: rel,
                thumbnailRef: rel, description: Self.str(row, "sourceLabel"),
                durationMs: nil, aspect: nil, isLocal: true
            )
        }
        return ListResult(items: items, hasMore: more)
    }

    // MARK: - Fetch / helpers

    private func fetchArray(path: String, keys: [String]) async throws -> [[String: Any]] {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AssetProviderError.badResponse(id) }
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AssetProviderError.http(id, code) }
        let json = try JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]] { return arr }
        if let obj = json as? [String: Any] {
            for key in keys where obj[key] is [[String: Any]] { return obj[key] as! [[String: Any]] }
        }
        return []
    }

    private func audioHaystack(_ row: [String: Any]) -> String {
        var parts = [Self.str(row, "title"), Self.str(row, "userTitle"), Self.str(row, "author"),
                     Self.str(row, "userAuthor"), Self.str(row, "name")].compactMap { $0 }
        for key in ["tags", "mood", "scene", "sfxCat"] {
            if let arr = row[key] as? [String] { parts.append(arr.joined(separator: " ")) }
        }
        return parts.joined(separator: " ")
    }

    private static func matches(_ hay: String, keys: [String]) -> Bool {
        let keys = keys.filter { !$0.isEmpty }.map { $0.lowercased() }
        guard !keys.isEmpty else { return true }
        let h = hay.lowercased()
        return keys.allSatisfy { h.contains($0) }
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

    private static func int(_ row: [String: Any], _ key: String) -> Int? {
        if let n = row[key] as? NSNumber { return n.intValue }
        return row[key] as? Int
    }
}

extension BridgeProvider {
    func mapForTesting(_ type: AssetType, _ rows: [[String: Any]]) -> [AssetCard] {
        // Mirrors list() mapping without the network fetch, for deterministic tests.
        switch type {
        case .music, .sfx:
            return rows.filter { (($0["kind"] as? String) == "sfx") == (type == .sfx) }.compactMap { row in
                guard let ref = Self.str(row, "sha256") ?? Self.str(row, "rel") else { return nil }
                let fileRef = Self.str(row, "rel") ?? ref
                let name = Self.str(row, "userTitle") ?? Self.str(row, "title") ?? Self.str(row, "name") ?? fileRef
                return AssetCard(id: ref, providerId: id, type: type, name: name, ref: fileRef,
                                 thumbnailRef: nil, description: nil,
                                 durationMs: Self.int(row, "durationMs"), aspect: nil, isLocal: true)
            }
        case .image:
            return rows.compactMap { row in
                guard let rel = Self.str(row, "rel") else { return nil }
                return AssetCard(id: rel, providerId: id, type: .image, name: (rel as NSString).lastPathComponent,
                                 ref: rel, thumbnailRef: rel, description: Self.str(row, "sourceLabel"),
                                 durationMs: nil, aspect: nil, isLocal: true)
            }
        case .video: return []
        }
    }
}
