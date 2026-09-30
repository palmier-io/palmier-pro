import Foundation

/// Pexels — free stock photography and, uniquely among the sources here, stock *video*.
/// Needs a free API key; without one the provider reports that it needs one rather than
/// failing the whole search.
struct PexelsProvider: StockMediaProvider {
    let id = "pexels"
    let displayName = "Pexels"
    let supportedKinds: Set<StockMediaKind> = [.image, .video]

    private static let base = URL(string: "https://api.pexels.com")!

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
    }

    func search(_ query: StockMediaQuery) async throws -> [StockMediaHit] {
        let key = await StockMediaCredentials.pexelsKey()
        guard !key.isEmpty else { throw StockMediaError.needsAPIKey(provider: displayName) }
        let headers = ["Authorization": key]

        switch query.kind {
        case .video:
            return try await searchVideos(query, headers: headers)
        case .image:
            return try await searchPhotos(query, headers: headers)
        case .audio:
            throw StockMediaError.unsupportedKind(provider: displayName)
        }
    }

    private func searchVideos(_ query: StockMediaQuery, headers: [String: String]) async throws -> [StockMediaHit] {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("videos/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "query", value: query.text),
            .init(name: "per_page", value: String(max(1, min(query.limit * 2, 80)))),
            .init(name: "orientation", value: query.orientation ?? "landscape"),
        ]
        guard let url = components?.url else { throw StockMediaError.emptyQuery }

        let data = try await StockMediaHTTP.getJSON(url, headers: headers)
        let response = try StockMediaHTTP.decode(VideoResponse.self, from: data, provider: displayName)

        let hits = response.videos.compactMap { video -> StockMediaHit? in
            guard let file = Self.bestFile(video.video_files) else { return nil }
            if let maxDuration = query.maxDurationSeconds, let duration = video.duration, duration > maxDuration {
                return nil
            }
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
        return Array(hits.prefix(max(1, query.limit)))
    }

    private func searchPhotos(_ query: StockMediaQuery, headers: [String: String]) async throws -> [StockMediaHit] {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("v1/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "query", value: query.text),
            .init(name: "per_page", value: String(max(1, min(query.limit * 2, 80)))),
            .init(name: "orientation", value: query.orientation ?? "landscape"),
        ]
        guard let url = components?.url else { throw StockMediaError.emptyQuery }

        let data = try await StockMediaHTTP.getJSON(url, headers: headers)
        let response = try StockMediaHTTP.decode(PhotoResponse.self, from: data, provider: displayName)

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
        return Array(hits.prefix(max(1, query.limit)))
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
