import Foundation

/// Pexels provides keyed photography and stock-video search.
struct PexelsProvider: StockMediaProvider {
    let id = "pexels"
    let displayName = "Pexels"
    let supportedKinds: Set<StockMediaKind> = [.image, .video]

    private static let base = URL(string: "https://api.pexels.com")!
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
        struct File: Decodable, Equatable {
            let quality: String?
            let file_type: String?
            let width: Int?
            let height: Int?
            let link: String
        }
        struct User: Decodable {
            let name: String?
            let url: String?
        }
        struct Video: Decodable {
            let id: Int
            let width: Int?
            let height: Int?
            let url: String?
            let image: String?
            let duration: Int?
            let user: User?
            let video_files: [File]?
        }
        let videos: [Video]
        let page: Int
        let next_page: String?
        let total_results: Int
    }

    private struct PhotoResponse: Decodable {
        struct Source: Decodable {
            let large2x: String?
            let large: String?
            let original: String?
        }
        struct Photo: Decodable {
            let id: Int
            let width: Int?
            let height: Int?
            let url: String?
            let photographer: String?
            let photographer_url: String?
            let src: Source?
        }
        let photos: [Photo]
        let page: Int
        let next_page: String?
        let total_results: Int
    }

    func search(_ query: StockMediaQuery) async throws -> StockMediaPage {
        try Task.checkCancellation()
        let query = try query.normalized()
        guard supportedKinds.contains(query.kind) else { throw StockMediaError.unsupportedKind(provider: displayName) }
        let key: String
        if let apiKey {
            key = apiKey
        } else {
            key = await StockMediaCredentials.pexelsKey()
            try Task.checkCancellation()
        }
        guard !key.isEmpty else { throw StockMediaError.needsAPIKey(provider: displayName) }
        let headers = ["Authorization": key]

        let page: StockMediaPage
        switch query.kind {
        case .video:
            page = try await searchVideos(query, headers: headers)
        case .image:
            page = try await searchPhotos(query, headers: headers)
        case .audio:
            throw StockMediaError.unsupportedKind(provider: displayName)
        }
        try Task.checkCancellation()
        return page
    }

    static func searchURL(_ query: StockMediaQuery) -> URL? {
        guard let query = try? query.normalized(), query.kind != .audio else { return nil }
        var components = URLComponents(
            url: Self.base.appendingPathComponent(query.kind == .video ? "v1/videos/search" : "v1/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "query", value: query.text),
            .init(name: "per_page", value: String(min(query.limit * 2, 80))),
            .init(name: "page", value: String(query.page)),
        ]
        if let orientation = query.orientation { components?.queryItems?.append(.init(name: "orientation", value: orientation)) }
        return components?.url
    }

    private func searchVideos(_ query: StockMediaQuery, headers: [String: String]) async throws -> StockMediaPage {
        guard let url = Self.searchURL(query) else { throw StockMediaError.emptyQuery }
        let data = try await requestJSON(url, headers)
        try Task.checkCancellation()
        let response = try StockMediaHTTP.decode(VideoResponse.self, from: data, provider: displayName)
        guard response.page == query.page, response.total_results >= 0 else { throw StockMediaError.undecodable(provider: displayName) }
        let nextPage = try StockMediaPage.continuation(response.next_page, requestURL: url, page: query.page, provider: displayName)

        let hits = response.videos.compactMap { video -> StockMediaHit? in
            guard let file = Self.bestFile(video.video_files) else { return nil }
            return StockMediaHit(
                id: "\(id)-video-\(video.id)",
                kind: .video,
                title: nil,
                url: file.link,
                thumbnailURL: video.image,
                creator: video.user?.name,
                creatorURL: video.user?.url,
                license: "Pexels License",
                licenseURL: "https://www.pexels.com/license/",
                providerID: id,
                landingPageURL: video.url,
                width: file.width ?? video.width,
                height: file.height ?? video.height,
                durationSeconds: video.duration,
                fileSizeBytes: nil,
                attributionText: nil
            )
        }
        return StockMediaPage(hits: hits.filter(query.includes), nextPage: nextPage, totalResults: response.total_results)
    }

    private func searchPhotos(_ query: StockMediaQuery, headers: [String: String]) async throws -> StockMediaPage {
        guard let url = Self.searchURL(query) else { throw StockMediaError.emptyQuery }

        let data = try await requestJSON(url, headers)
        try Task.checkCancellation()
        let response = try StockMediaHTTP.decode(PhotoResponse.self, from: data, provider: displayName)
        guard response.page == query.page, response.total_results >= 0 else { throw StockMediaError.undecodable(provider: displayName) }
        let nextPage = try StockMediaPage.continuation(response.next_page, requestURL: url, page: query.page, provider: displayName)

        let hits = response.photos.compactMap { photo -> StockMediaHit? in
            // large2x is a sensible default: big enough to hold a full-frame still, far smaller
            // than most originals.
            guard let fileURL = photo.src?.large2x ?? photo.src?.large ?? photo.src?.original else { return nil }
            return StockMediaHit(
                id: "\(id)-photo-\(photo.id)",
                kind: .image,
                title: nil,
                url: fileURL,
                thumbnailURL: nil,
                creator: photo.photographer,
                creatorURL: photo.photographer_url,
                license: "Pexels License",
                licenseURL: "https://www.pexels.com/license/",
                providerID: id,
                landingPageURL: photo.url,
                width: photo.width,
                height: photo.height,
                durationSeconds: nil,
                fileSizeBytes: nil,
                attributionText: nil
            )
        }
        return StockMediaPage(hits: hits.filter(query.includes), nextPage: nextPage, totalResults: response.total_results)
    }

    /// Prefers a real progressive MP4, then the smallest HD rendition. HLS entries have no
    /// dimensions and are streams rather than files, so they are never importable.
    static func bestFile(_ files: [VideoResponse.File]?) -> VideoResponse.File? {
        guard let files, !files.isEmpty else { return nil }
        let progressive = files.filter { $0.file_type == "video/mp4" && $0.width != nil && $0.height != nil }
        let pool = progressive.isEmpty ? [] : progressive
        guard !pool.isEmpty else { return nil }
        let hd = pool.filter { $0.quality == "hd" }
        if !hd.isEmpty {
            // Among HD renditions take the smallest: 1080p is plenty for a cut and the
            // 4096-wide variants are needlessly heavy to download.
            return hd.min { lhs, rhs in
                (lhs.width ?? 0) * (lhs.height ?? 0) < (rhs.width ?? 0) * (rhs.height ?? 0)
            }
        }
        return pool.min { lhs, rhs in
            (lhs.width ?? 0) * (lhs.height ?? 0) < (rhs.width ?? 0) * (rhs.height ?? 0)
        }
    }
}
