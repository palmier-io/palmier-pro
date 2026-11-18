import CryptoKit
import Foundation

/// 24-hour on-disk cache for provider search responses. Caching raw response bytes keeps decoding,
/// paging, and provider-specific normalization in exactly one place. Entries expire by file age, so
/// a clock change cannot resurrect stale provider data.
struct StockMediaRequestCache: Sendable {
    static let ttl: TimeInterval = 24 * 60 * 60

    let cache: DiskCache
    let now: @Sendable () -> Date

    init(cache: DiskCache = DiskCache(named: "StockMedia/Requests"), now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.now = now
    }

    static let shared = StockMediaRequestCache()

    /// Provider + normalized query. Excluded sources stay out of the key: they filter hits locally
    /// and must not fragment one provider request per excluded id.
    static func key(provider: String, query: StockMediaQuery) -> String {
        [
            provider,
            query.text.lowercased(),
            query.kind.rawValue,
            query.orientation ?? "-",
            query.maxDurationSeconds.map(String.init) ?? "-",
            String(query.limit),
            String(query.page),
        ].joined(separator: "|")
    }

    @concurrent
    func cachedResponse(key: String) async -> Data? {
        let url = fileURL(for: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        let age = now().timeIntervalSince(modified)
        guard age >= 0, age < Self.ttl else { return nil }
        return data
    }

    @concurrent
    func store(_ data: Data, key: String) async {
        guard !data.isEmpty else { return }
        let url = fileURL(for: key)
        try? FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: cache.directory)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cache.directory.appendingPathComponent(digest + ".json", isDirectory: false)
    }
}
