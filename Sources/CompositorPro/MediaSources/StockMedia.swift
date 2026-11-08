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
}

enum StockMediaError: LocalizedError, Equatable {
    case emptyQuery
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
    func search(_ query: StockMediaQuery) async throws -> [StockMediaHit]
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

    var receipt: [String: Any] {
        var out: [String: Any] = [
            "provider": id,
            "displayName": displayName,
            "status": status.rawValue,
            "count": count,
        ]
        if let message { out["message"] = message }
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
    static func search(_ query: StockMediaQuery) async throws -> StockMediaResult {
        let (hits, outcomes, totals, scoped) = try await collect(query)
        return try finalize(hits: hits, outcomes: outcomes, totals: totals, query: scoped)
    }

    /// Runs every provider against one normalized query and preserves each source's outcome.
    /// Unlike `search`, this does not treat an empty aggregate as a failure; a unified caller
    /// may still have local candidates and must see exactly which remote sources succeeded.
    static func collect(_ query: StockMediaQuery) async throws -> (
        hits: [StockMediaHit],
        outcomes: [StockProviderOutcome],
        totals: [Int],
        query: StockMediaQuery
    ) {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StockMediaError.emptyQuery }

        var scoped = query
        scoped.text = text
        // Every provider is queried at once; keyless and keyed sources both report their own
        // availability, and a keyless source must not wait on a keyed one.
        let providers: [any StockMediaProvider] = [OpenverseProvider(), PexelsProvider(), PixabayProvider()]

        var outcomes: [StockProviderOutcome] = []
        var collected: [StockMediaHit] = []
        var totals: [Int] = []

        for provider in providers {
            try Task.checkCancellation()
            guard provider.supportedKinds.contains(scoped.kind) else {
                outcomes.append(.init(
                    id: provider.id,
                    displayName: provider.displayName,
                    status: .unsupportedKind,
                    count: 0,
                    message: "\(provider.displayName) does not provide \(scoped.kind.rawValue) media."
                ))
                continue
            }
            do {
                let hits = try await provider.search(scoped)
                totals.append(hits.count)
                collected.append(contentsOf: hits)
                outcomes.append(.init(
                    id: provider.id,
                    displayName: provider.displayName,
                    status: .ok,
                    count: hits.count,
                    message: nil
                ))
            } catch {
                if error is CancellationError { throw error }
                if let error = error as? StockMediaError {
                    outcomes.append(.init(
                        id: provider.id,
                        displayName: provider.displayName,
                        status: status(for: error),
                        count: 0,
                        message: error.errorDescription
                    ))
                } else {
                    outcomes.append(.init(
                        id: provider.id,
                        displayName: provider.displayName,
                        status: .failed,
                        count: 0,
                        message: error.localizedDescription
                    ))
                }
            }
        }
        return (collected, outcomes, totals, scoped)
    }

    private static func finalize(
        hits: [StockMediaHit],
        outcomes: [StockProviderOutcome],
        totals: [Int],
        query: StockMediaQuery
    ) throws -> StockMediaResult {
        // A video search with at least one working provider and no usable hits is a real
        // absence; for images and audio an empty result may simply mean every source missed.
        let usable = dedupe(hits).prefix(query.limit)
        guard !usable.isEmpty else {
            if query.kind == .video, outcomes.contains(where: { $0.status == .ok }) {
                throw StockMediaError.noUsableResults
            }
            return StockMediaResult(hits: [], outcomes: outcomes, totalResults: nil)
        }
        return StockMediaResult(hits: Array(usable), outcomes: outcomes, totalResults: totals.max())
    }

    private static func status(for error: StockMediaError) -> StockProviderOutcome.Status {
        switch error {
        case .needsAPIKey: .needsAPIKey
        case .rateLimited: .rateLimited
        default: .failed
        }
    }

    private static func dedupe(_ hits: [StockMediaHit]) -> [StockMediaHit] {
        var seen = Set<String>()
        return hits.filter { seen.insert($0.url).inserted }
    }
}
