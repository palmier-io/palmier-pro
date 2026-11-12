import Foundation

/// Pixabay provides keyed stock-video search.
struct PixabayProvider: StockMediaProvider {
    let id = "pixabay"
    let displayName = "Pixabay"
    let supportedKinds: Set<StockMediaKind> = [.video]

    private static let base = URL(string: "https://pixabay.com/api/videos/")!
    private static let license = "Pixabay Content License"
    private static let licenseURL = "https://pixabay.com/service/license-summary/"

    /// Injected for tests so a missing-key refusal can be verified without Keychain or network
    /// access. Production uses the stored credential.
    private let apiKey: String?
    private let requestJSON: StockMediaJSONRequest

    init(
        apiKey: String? = nil,
        requestJSON: @escaping StockMediaJSONRequest = { try await StockMediaHTTP.getJSON($0, headers: $1) }
    ) {
        self.apiKey = apiKey
        self.requestJSON = requestJSON
    }

    struct VideoResponse: Decodable {
        struct Rendition: Decodable, Equatable {
            let url: String?
            let width: Int?
            let height: Int?
            let size: Int?
            let thumbnail: String?
        }
        struct Video: Decodable {
            let id: Int
            let pageURL: String?
            let tags: String?
            let duration: Int?
            let videos: [String: Rendition]?
            let user: String?
        }
        let hits: [Video]
        let totalHits: Int
    }

    static func searchURL(_ query: StockMediaQuery, key: String) -> URL? {
        guard !key.isEmpty, let query = try? query.normalized() else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "key", value: key),
            .init(name: "q", value: query.text),
            .init(name: "per_page", value: String(pageSize(query))),
            .init(name: "page", value: String(query.page)),
            .init(name: "safesearch", value: "true"),
        ]
        return components?.url
    }

    private static func pageSize(_ query: StockMediaQuery) -> Int { max(3, query.limit * 2) }

    func search(_ query: StockMediaQuery) async throws -> StockMediaPage {
        try Task.checkCancellation()
        let query = try query.normalized()
        guard supportedKinds.contains(query.kind) else { throw StockMediaError.unsupportedKind(provider: displayName) }
        let key: String
        if let apiKey {
            key = apiKey
        } else {
            key = await StockMediaCredentials.pixabayKey()
            try Task.checkCancellation()
        }
        guard !key.isEmpty else { throw StockMediaError.needsAPIKey(provider: displayName) }
        guard let url = Self.searchURL(query, key: key) else { throw StockMediaError.emptyQuery }

        let data = try await requestJSON(url, [:])
        try Task.checkCancellation()
        let response = try StockMediaHTTP.decode(VideoResponse.self, from: data, provider: displayName)
        guard response.totalHits >= 0 else { throw StockMediaError.undecodable(provider: displayName) }
        let hits = response.hits.compactMap { Self.hit($0, query: query) }
        let nextPage = query.page * Self.pageSize(query) < response.totalHits ? query.page + 1 : nil
        return StockMediaPage(hits: hits, nextPage: nextPage, totalResults: response.totalHits)
    }

    static func hit(_ video: VideoResponse.Video, query: StockMediaQuery) -> StockMediaHit? {
        guard let rendition = bestRendition(video.videos),
              let fileURL = httpsURL(rendition.url) else { return nil }
        let creator = video.user?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution = creator.map { "Video by \($0) via Pixabay" } ?? "Video via Pixabay"
        let creatorName = (creator?.isEmpty == true) ? nil : creator
        let hitID = "\(Self.providerID)-video-\(video.id)"
        let hit = StockMediaHit(
            id: hitID,
            kind: .video,
            title: title(tags: video.tags),
            url: fileURL,
            thumbnailURL: rendition.thumbnail,
            creator: creatorName,
            creatorURL: nil,
            license: license,
            licenseURL: licenseURL,
            providerID: Self.providerID,
            landingPageURL: video.pageURL,
            width: rendition.width,
            height: rendition.height,
            durationSeconds: video.duration,
            fileSizeBytes: rendition.size,
            attributionText: attribution
        )
        return query.includes(hit) ? hit : nil
    }

    private static let providerID = "pixabay"

    private static func title(tags: String?) -> String? {
        let tags = tags?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tags.isEmpty ? nil : tags
    }

    /// Pixabay documents `medium` as available for every video, so it is the default. Otherwise
    /// use the smallest usable rendition; an empty URL is a stream placeholder, not a file.
    static func bestRendition(_ renditions: [String: VideoResponse.Rendition]?) -> VideoResponse.Rendition? {
        guard let renditions, !renditions.isEmpty else { return nil }
        let usable = renditions.values.compactMap { rendition -> (file: VideoResponse.Rendition, pixels: Int)? in
            guard let url = rendition.url, !url.isEmpty,
                  let pixels = StockMediaDimensions.pixelCount(width: rendition.width, height: rendition.height) else { return nil }
            return (rendition, pixels)
        }
        if let medium = renditions["medium"], usable.contains(where: { $0.file == medium }) { return medium }
        return usable.min {
            ($0.file.size ?? Int.max, $0.pixels) < ($1.file.size ?? Int.max, $1.pixels)
        }?.file
    }

    private static func httpsURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return value
    }
}
