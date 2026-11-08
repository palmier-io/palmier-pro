import Foundation

/// A downloadable, openly-licensed media candidate from a free source.
///
/// The direct `url` is what `import_media` fetches; the license fields exist because most of
/// these sources require the creator to be credited, and the credit has to survive the trip
/// from a tool receipt to wherever the finished cut is published.
struct StockMediaHit: Sendable, Equatable {
    let id: String
    let kind: StockMediaKind
    let title: String?
    /// Direct file URL, HTTPS. Importable by `import_media` as-is.
    let url: String
    let thumbnailURL: String?
    let creator: String?
    let creatorURL: String?
    let license: String
    let licenseURL: String?
    let providerID: String
    let landingPageURL: String?
    let width: Int?
    let height: Int?
    let durationSeconds: Int?
    let fileSizeBytes: Int?
    /// A ready-made credit line when the source supplies one; it knows the license wording
    /// better than anything reconstructed from the license fields.
    let attributionText: String?

    /// One line the user can paste into credits.
    var attribution: String {
        if let attributionText, !attributionText.isEmpty { return attributionText }
        let author = creator.map { " by \($0)" } ?? ""
        let licensePart = licenseURL.map { " (\($0))" } ?? " (\(license))"
        return "\(kind.rawValue.capitalized)\(author) — \(license)\(licensePart)"
    }

    var origin: MediaImportOrigin {
        MediaImportOrigin(provider: providerID, assetId: id, landingPageURL: landingPageURL)
    }

    var receipt: [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "url": url,
            "license": license,
            "provider": providerID,
        ]
        out["title"] = title
        out["origin"] = origin.receipt
        out["thumbnailUrl"] = thumbnailURL
        out["creator"] = creator
        out["creatorUrl"] = creatorURL
        out["licenseUrl"] = licenseURL
        out["landingPage"] = landingPageURL
        out["width"] = width
        out["height"] = height
        out["durationSeconds"] = durationSeconds
        out["fileSizeBytes"] = fileSizeBytes
        out["attribution"] = attribution
        return out
    }
}
enum StockMediaKind: String, CaseIterable, Sendable {
    case image, audio, video

    /// What the user asked for, and what the providers between them can actually serve.
    static func parse(_ raw: String) -> StockMediaKind? {
        StockMediaKind(rawValue: raw)
    }
}

struct StockMediaQuery: Sendable {
    var text: String
    var kind: StockMediaKind
    var orientation: String?
    var maxDurationSeconds: Int?
    var limit: Int
    var page: Int = 1
    var excludedSourceIds: Set<String> = []

    func normalized() throws -> Self {
        var query = self
        query.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.text.isEmpty else { throw StockMediaError.emptyQuery }
        guard (1...50).contains(limit) else { throw StockMediaError.invalidQuery(field: "limit") }
        guard (1...500).contains(page) else { throw StockMediaError.invalidQuery(field: "page") }
        if let orientation {
            guard kind != .audio, ["landscape", "portrait", "square"].contains(orientation) else {
                throw StockMediaError.invalidQuery(field: "orientation")
            }
        }
        if let maxDurationSeconds {
            guard kind != .image, maxDurationSeconds > 0 else {
                throw StockMediaError.invalidQuery(field: "maxDurationSeconds")
            }
        }
        guard excludedSourceIds.allSatisfy(Self.isStockSourceId) else {
            throw StockMediaError.invalidQuery(field: "excludedSourceIds")
        }
        return query
    }

    private static func isStockSourceId(_ value: String) -> Bool {
        value.hasPrefix("stock:") && VisualSourceAliases.isCanonicalSourceId(value)
    }

    func includes(_ hit: StockMediaHit) -> Bool {
        guard hit.kind == kind, !excludedSourceIds.contains(hit.origin.sourceId),
              let url = URL(string: hit.url), url.scheme == "https", url.host?.isEmpty == false else { return false }
        if let maxDurationSeconds {
            guard let duration = hit.durationSeconds, duration > 0, duration <= maxDurationSeconds else { return false }
        }
        if let orientation {
            guard let width = hit.width, let height = hit.height, width > 0, height > 0 else { return false }
            switch orientation {
            case "landscape": guard width > height else { return false }
            case "portrait": guard height > width else { return false }
            case "square": guard width == height else { return false }
            default: return false
            }
        }
        return true
    }
}

enum StockMediaError: LocalizedError, Equatable {
    case emptyQuery
    case invalidQuery(field: String)
    case needsAPIKey(provider: String)
    case badStatus(provider: String, code: Int)
    case rateLimited(provider: String)
    case undecodable(provider: String)
    case unsupportedKind(provider: String)
    case noUsableResults

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "Search text is required."
        case .invalidQuery(let field):
            switch field {
            case "limit": "Stock search limit must be 1–50."
            case "page": "Stock search page must be 1–500."
            case "orientation": "Stock search orientation must be landscape, portrait, or square and cannot apply to audio."
            case "maxDurationSeconds": "Stock search duration must be positive and can apply only to audio or video."
            case "excludedSourceIds": "Stock search exclusions must contain valid stock source IDs, each at most 256 UTF-8 bytes."
            default: "Invalid stock search \(field)."
            }
        case .needsAPIKey(let provider):
            "\(provider) needs a free API key before it can search. Add it in Settings, then retry."
        case .badStatus(let provider, let code):
            "\(provider) returned HTTP \(code)."
        case .rateLimited(let provider):
            "\(provider) rate-limited this request. Wait a moment and retry."
        case .undecodable(let provider):
            "\(provider) returned a response this app could not read."
        case .unsupportedKind(let provider):
            "\(provider) does not provide that kind of media."
        case .noUsableResults:
            "No provider returned a downloadable result for that search."
        }
    }
}

protocol StockMediaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedKinds: Set<StockMediaKind> { get }

    /// Throws `StockMediaError.needsAPIKey` when the provider is configured but unusable.
    func search(_ query: StockMediaQuery) async throws -> StockMediaPage
}

typealias StockMediaJSONRequest = @Sendable (URL, [String: String]) async throws -> Data

struct StockMediaPage: Sendable {
    let hits: [StockMediaHit]
    let nextPage: Int?
    let totalResults: Int?

    init(hits: [StockMediaHit], nextPage: Int? = nil, totalResults: Int? = nil) {
        self.hits = hits
        self.nextPage = nextPage
        self.totalResults = totalResults
    }

    static func continuation(_ value: String?, requestURL: URL, page: Int, provider: String) throws -> Int? {
        guard let value else { return nil }
        guard let components = URLComponents(string: value), components.scheme == "https",
              components.host == requestURL.host, components.port == requestURL.port,
              components.user == nil, components.password == nil,
              components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let items = components.queryItems else { throw StockMediaError.undecodable(provider: provider) }
        let pages = items.filter { $0.name == "page" }
        guard pages.count == 1, let raw = pages.first?.value, let next = Int(raw), next > page else {
            throw StockMediaError.undecodable(provider: provider)
        }
        return next
    }
}

/// Per-provider outcome, so a receipt never implies every source was searched successfully.
struct StockProviderOutcome: Sendable {
    enum Status: String, Sendable {
        case ok, needsAPIKey, rateLimited, failed, unsupportedKind
    }

    let id: String
    let displayName: String
    let status: Status
    let count: Int
    let message: String?
    let pagesFetched: Int
    let exhausted: Bool
    let nextPage: Int?
    let totalResults: Int?

    init(
        id: String, displayName: String, status: Status, count: Int, message: String?,
        pagesFetched: Int = 0, exhausted: Bool = false, nextPage: Int? = nil, totalResults: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.count = count
        self.message = message
        self.pagesFetched = pagesFetched
        self.exhausted = exhausted
        self.nextPage = nextPage
        self.totalResults = totalResults
    }

    var receipt: [String: Any] {
        var out: [String: Any] = [
            "provider": id,
            "displayName": displayName,
            "status": status.rawValue,
            "count": count,
            "pagesFetched": pagesFetched,
            "exhausted": exhausted,
        ]
        if let message { out["message"] = message }
        out["nextPage"] = nextPage
        out["totalResults"] = totalResults
        return out
    }
}

struct StockMediaResult: Sendable {
    let hits: [StockMediaHit]
    let outcomes: [StockProviderOutcome]
    var totalResults: Int?
}

/// Free, openly-licensed media search. Openverse covers images and audio with no
/// credentials. Pixabay carries free video search once the user supplies a key; Pexels remains
/// available for photography and video on accounts that already hold a key.
enum StockMediaSearch {
    static var defaultProviders: [any StockMediaProvider] {
        [OpenverseProvider(), PexelsProvider(), PixabayProvider()]
    }

    static func search(
        _ query: StockMediaQuery, providers: [any StockMediaProvider] = defaultProviders
    ) async throws -> StockMediaResult {
        let (hits, outcomes, totals, scoped) = try await collect(query, providers: providers)
        try Task.checkCancellation()
        return try finalize(hits: hits, outcomes: outcomes, totals: totals, query: scoped)
    }

    /// Runs every provider against one normalized query and preserves each source's outcome.
    /// Unlike `search`, this does not treat an empty aggregate as a failure; a unified caller
    /// may still have local candidates and must see exactly which remote sources succeeded.
    static func collect(
        _ query: StockMediaQuery, providers: [any StockMediaProvider] = defaultProviders
    ) async throws -> (
        hits: [StockMediaHit],
        outcomes: [StockProviderOutcome],
        totals: [Int],
        query: StockMediaQuery
    ) {
        try Task.checkCancellation()
        let scoped = try query.normalized()
        let results = try await withThrowingTaskGroup(of: (Int, ProviderCollection).self) { group in
            var results = [ProviderCollection?](repeating: nil, count: providers.count)
            var scheduled = min(2, providers.count)
            for index in 0..<scheduled {
                let provider = providers[index]
                group.addTask { (index, try await collectProvider(provider, query: scoped)) }
            }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                results[index] = result
                if scheduled < providers.count {
                    let nextIndex = scheduled
                    let provider = providers[nextIndex]
                    group.addTask { (nextIndex, try await collectProvider(provider, query: scoped)) }
                    scheduled += 1
                }
            }
            return results.compactMap { $0 }
        }
        try Task.checkCancellation()
        let outcomes = results.map(\.outcome)
        let totals = outcomes.compactMap(\.totalResults)
        return (interleave(results.map(\.hits), query: scoped), outcomes, totals, scoped)
    }

    private struct ProviderCollection: Sendable {
        let hits: [StockMediaHit]
        let outcome: StockProviderOutcome
    }

    private static func collectProvider(_ provider: any StockMediaProvider, query: StockMediaQuery) async throws -> ProviderCollection {
        try Task.checkCancellation()
        guard provider.supportedKinds.contains(query.kind) else {
            return ProviderCollection(hits: [], outcome: .init(
                id: provider.id, displayName: provider.displayName, status: .unsupportedKind, count: 0,
                message: "\(provider.displayName) does not provide \(query.kind.rawValue) media."
            ))
        }
        var hits: [StockMediaHit] = []
        var seen = Set<String>()
        var pagesFetched = 0
        var nextPage: Int?
        var totalResults: Int?
        var exhausted = false
        var pageQuery = query
        var status = StockProviderOutcome.Status.ok
        var message: String?
        do {
            while pagesFetched < 3 {
                try Task.checkCancellation()
                let page = try await provider.search(pageQuery)
                try Task.checkCancellation()
                guard page.totalResults.map({ $0 >= 0 }) ?? true,
                      page.nextPage.map({ $0 > pageQuery.page }) ?? true else {
                    throw StockMediaError.undecodable(provider: provider.displayName)
                }
                pagesFetched += 1
                nextPage = page.nextPage
                if let total = page.totalResults { totalResults = total }
                exhausted = nextPage == nil
                for hit in page.hits where query.includes(hit) {
                    if seen.insert(hit.origin.sourceId).inserted { hits.append(hit) }
                }
                guard hits.count < query.limit, let nextPage, nextPage <= 500 else { break }
                pageQuery.page = nextPage
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            status = (error as? StockMediaError).map { Self.status(for: $0) } ?? .failed
            message = error.localizedDescription
        }
        return ProviderCollection(hits: hits, outcome: .init(
            id: provider.id, displayName: provider.displayName, status: status, count: hits.count, message: message,
            pagesFetched: pagesFetched, exhausted: exhausted, nextPage: nextPage, totalResults: totalResults
        ))
    }

    private static func interleave(_ lists: [[StockMediaHit]], query: StockMediaQuery) -> [StockMediaHit] {
        var hits: [StockMediaHit] = []
        var seen = Set<String>()
        var indices = [Int](repeating: 0, count: lists.count)
        var advanced = true
        while advanced, hits.count < query.limit {
            advanced = false
            for index in lists.indices {
                while indices[index] < lists[index].count {
                    let hit = lists[index][indices[index]]
                    indices[index] += 1
                    advanced = true
                    guard seen.insert(hit.origin.sourceId).inserted else { continue }
                    hits.append(hit)
                    break
                }
                if hits.count == query.limit { break }
            }
        }
        return hits
    }

    private static func finalize(
        hits: [StockMediaHit],
        outcomes: [StockProviderOutcome],
        totals: [Int],
        query: StockMediaQuery
    ) throws -> StockMediaResult {
        guard !hits.isEmpty else {
            let supported = outcomes.filter { $0.status != .unsupportedKind }
            if query.kind == .video, !supported.isEmpty, supported.allSatisfy({ $0.status == .ok && $0.exhausted }) {
                throw StockMediaError.noUsableResults
            }
            return StockMediaResult(hits: [], outcomes: outcomes, totalResults: totals.max())
        }
        return StockMediaResult(hits: hits, outcomes: outcomes, totalResults: totals.max())
    }

    private static func status(for error: StockMediaError) -> StockProviderOutcome.Status {
        switch error {
        case .needsAPIKey: .needsAPIKey
        case .rateLimited: .rateLimited
        default: .failed
        }
    }
}
