import Foundation

/// Openverse — keyless Creative Commons search across Flickr, Freesound, and others.
/// Covers images and audio. There is no video collection, so video requests are refused
/// up front rather than answered with an empty list.
struct OpenverseProvider: StockMediaProvider {
    let id = "openverse"
    let displayName = "Openverse"
    let supportedKinds: Set<StockMediaKind> = [.image, .audio]

    private static let base = URL(string: "https://api.openverse.org/v1")!
    private let requestJSON: StockMediaJSONRequest

    init(requestJSON: @escaping StockMediaJSONRequest = { try await StockMediaHTTP.getJSON($0, headers: $1) }) {
        self.requestJSON = requestJSON
    }

    struct Response: Decodable {
        struct Result: Decodable {
            let id: String
            let title: String?
            let url: String?
            let thumbnail: String?
            let foreign_landing_url: String?
            let creator: String?
            let creator_url: String?
            let license: String?
            let license_version: String?
            let license_url: String?
            let attribution: String?
            let filesize: Int?
            let filetype: String?
            let width: Int?
            let height: Int?
            /// Milliseconds, and only present on the audio collection.
            let duration: Int?
            let mature: Bool?
        }
        let results: [Result]
        let page: Int
        let page_count: Int
        let result_count: Int
    }

    static func searchURL(_ query: StockMediaQuery) -> URL? {
        guard let query = try? query.normalized(), query.kind != .video,
              (try? validatePagination(query)) != nil else { return nil }
        let path = query.kind == .audio ? "audio" : "images"
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "q", value: query.text),
            .init(name: "page_size", value: String(pageSize(query))),
            .init(name: "page", value: String(query.page)),
            // Single value, deliberately. Openverse only honours one `license_type`, and
            // joining values silently degrades to no filtering at all — which offers NC and ND
            // results that cannot legally go in a cut. `commercial` is what excludes both.
            .init(name: "license_type", value: "commercial"),
        ]
        return components?.url
    }

    private static func pageSize(_ query: StockMediaQuery) -> Int { min(query.limit * 2, 20) }

    private static func validatePagination(_ query: StockMediaQuery) throws {
        guard query.page <= 240 / pageSize(query) else {
            throw StockMediaError.invalidQuery(field: "openversePaginationDepth")
        }
    }

    func search(_ query: StockMediaQuery) async throws -> StockMediaPage {
        try Task.checkCancellation()
        let query = try query.normalized()
        guard supportedKinds.contains(query.kind) else { throw StockMediaError.unsupportedKind(provider: displayName) }
        try Self.validatePagination(query)
        guard let url = Self.searchURL(query) else { throw StockMediaError.emptyQuery }
        let data = try await requestJSON(url, [:])
        try Task.checkCancellation()
        let response = try StockMediaHTTP.decode(Response.self, from: data, provider: displayName)
        guard response.page == query.page, response.result_count >= 0,
              response.page_count >= query.page
                || (response.page_count == 0 && response.result_count == 0 && response.results.isEmpty) else {
            throw StockMediaError.undecodable(provider: displayName)
        }

        let hits = response.results.compactMap { result -> StockMediaHit? in
            // `url` is the direct file; without it there is nothing for import_media to fetch.
            guard let fileURL = result.url, !fileURL.isEmpty else { return nil }
            // Stock footage search has no business surfacing flagged material.
            guard result.mature != true else { return nil }
            if let maximum = query.maxDurationSeconds {
                guard let milliseconds = result.duration, milliseconds > 0,
                      milliseconds / 1000 < maximum || (milliseconds / 1000 == maximum && milliseconds % 1000 == 0) else {
                    return nil
                }
            }
            let license = result.license.map { "\($0.uppercased())\(result.license_version.map { " \($0)" } ?? "")" }
                ?? "Creative Commons"
            return StockMediaHit(
                id: "\(id)-\(result.id)",
                kind: query.kind,
                title: result.title,
                url: fileURL,
                thumbnailURL: result.thumbnail,
                creator: result.creator,
                creatorURL: result.creator_url,
                license: license,
                licenseURL: result.license_url,
                providerID: id,
                landingPageURL: result.foreign_landing_url ?? result.creator_url,
                width: result.width,
                height: result.height,
                durationSeconds: result.duration.flatMap { milliseconds in
                    guard milliseconds > 0 else { return nil }
                    return milliseconds / 1000 + (milliseconds % 1000 == 0 ? 0 : 1)
                },
                fileSizeBytes: result.filesize,
                attributionText: result.attribution
            )
        }
        let nextPage = query.page < response.page_count ? query.page + 1 : nil
        return StockMediaPage(hits: hits.filter(query.includes), nextPage: nextPage, totalResults: response.result_count)
    }
}
