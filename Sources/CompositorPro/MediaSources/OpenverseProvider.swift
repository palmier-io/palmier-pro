import Foundation

/// Openverse — keyless Creative Commons search across Flickr, Freesound, and others.
/// Covers images and audio. There is no video collection, so video requests are refused
/// up front rather than answered with an empty list.
struct OpenverseProvider: StockMediaProvider {
    let id = "openverse"
    let displayName = "Openverse"
    let supportedKinds: Set<StockMediaKind> = [.image, .audio]

    private static let base = URL(string: "https://api.openverse.org/v1")!

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
    }

    func search(_ query: StockMediaQuery) async throws -> [StockMediaHit] {
        let path = query.kind == .audio ? "audio" : "images"
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "q", value: query.text),
            .init(name: "page_size", value: String(max(1, min(query.limit * 2, 20)))),
            // Single value, deliberately. Openverse only honours one `license_type`, and
            // joining values silently degrades to no filtering at all — which offers NC and ND
            // results that cannot legally go in a cut. `commercial` is what excludes both.
            .init(name: "license_type", value: "commercial"),
        ]
        guard let url = components?.url else { throw StockMediaError.emptyQuery }

        let data = try await StockMediaHTTP.getJSON(url)
        let response = try StockMediaHTTP.decode(Response.self, from: data, provider: displayName)

        let hits = response.results.compactMap { result -> StockMediaHit? in
            // `url` is the direct file; without it there is nothing for import_media to fetch.
            guard let fileURL = result.url, !fileURL.isEmpty else { return nil }
            // Stock footage search has no business surfacing flagged material.
            guard result.mature != true else { return nil }
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
                durationSeconds: result.duration.map { $0 / 1000 },
                fileSizeBytes: result.filesize,
                attributionText: result.attribution
            )
        }
        // Over-fetched above so dropping unusable rows still fills the requested limit.
        return Array(hits.prefix(max(1, query.limit)))
    }
}
