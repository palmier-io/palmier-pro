import Foundation

/// Pixabay — the currently working free stock-video source. Pixabay still issues free API keys;
/// Pexels issuance is paused, so Pixabay carries video retrieval. This provider intentionally
/// covers video only and leaves Pexels photography/video in place for accounts that already hold
/// a key.
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

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
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
    }

    static func searchURL(_ query: StockMediaQuery, key: String) -> URL? {
        guard !key.isEmpty else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "key", value: key),
            .init(name: "q", value: query.text),
            .init(name: "per_page", value: String(max(3, min(max(query.limit, 1) * 2, 200)))),
            .init(name: "safesearch", value: "true"),
        ]
        return components?.url
    }

    func search(_ query: StockMediaQuery) async throws -> [StockMediaHit] {
        let key: String
        if let apiKey {
            key = apiKey
        } else {
            key = await StockMediaCredentials.pixabayKey()
        }
        guard !key.isEmpty else { throw StockMediaError.needsAPIKey(provider: displayName) }
        guard let url = Self.searchURL(query, key: key) else { throw StockMediaError.emptyQuery }

        let data = try await StockMediaHTTP.getJSON(url)
        let response = try StockMediaHTTP.decode(VideoResponse.self, from: data, provider: displayName)
        let hits = response.hits.compactMap { Self.hit($0, query: query) }
        return Array(hits.prefix(max(1, query.limit)))
    }

    static func hit(_ video: VideoResponse.Video, query: StockMediaQuery) -> StockMediaHit? {
        guard let rendition = bestRendition(video.videos),
              let fileURL = httpsURL(rendition.url) else { return nil }
        if let maxDuration = query.maxDurationSeconds, let duration = video.duration, duration > maxDuration {
            return nil
        }
        let creator = video.user?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution = creator.map { "Video by \($0) via Pixabay" } ?? "Video via Pixabay"
        let creatorName = (creator?.isEmpty == true) ? nil : creator
        let hitID = "\(Self.providerID)-video-\(video.id)"
        return StockMediaHit(
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
        let usable = renditions.values.filter { rendition in
            guard let url = rendition.url, !url.isEmpty,
                  let width = rendition.width, width > 0,
                  let height = rendition.height, height > 0 else { return false }
            return true
        }
        if let medium = renditions["medium"], usable.contains(medium) { return medium }
        return usable.min {
            ($0.size ?? Int.max, ($0.width ?? 0) * ($0.height ?? 0)) <
            ($1.size ?? Int.max, ($1.width ?? 0) * ($1.height ?? 0))
        }
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
