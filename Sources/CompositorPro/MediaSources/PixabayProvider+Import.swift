import Foundation

extension PixabayProvider {
    static func videoID(from pageURL: URL) -> Int? {
        guard pageURL.scheme == "https", pageURL.user == nil, pageURL.password == nil,
              pageURL.port == nil || pageURL.port == 443,
              ["pixabay.com", "www.pixabay.com"].contains(pageURL.host?.lowercased() ?? "") else { return nil }
        let parts = pageURL.path.split(separator: "/")
        guard parts.count == 2 || parts.count == 3,
              parts[parts.count - 2] == "videos",
              let rawID = parts.last?.split(separator: "-").last,
              rawID.allSatisfy({ $0.isASCII && $0.isNumber }),
              let id = Int(rawID), id > 0 else { return nil }
        return id
    }

    @concurrent func resolveVideoPage(_ pageURL: URL) async throws -> StockMediaHit {
        try Task.checkCancellation()
        guard let id = Self.videoID(from: pageURL) else {
            throw ToolError("Expected a Pixabay video page URL")
        }
        let key = if let apiKey { apiKey } else { await StockMediaCredentials.pixabayKey() }
        try Task.checkCancellation()
        if !key.isEmpty {
            var components = URLComponents(string: "https://pixabay.com/api/videos/")!
            components.queryItems = [.init(name: "key", value: key), .init(name: "id", value: String(id))]
            let data = try await requestJSON(components.url!, [:])
            try Task.checkCancellation()
            let response = try StockMediaHTTP.decode(VideoResponse.self, from: data, provider: displayName)
            let query = StockMediaQuery(text: String(id), kind: .video, limit: 1)
            guard let video = response.hits.first(where: { $0.id == id }),
                  let hit = Self.hit(video, query: query) else {
                throw ToolError("Pixabay video \(id) has no downloadable rendition")
            }
            return hit
        }
        let data = try await requestPage(pageURL)
        try Task.checkCancellation()
        let fileURL = try await Self.videoURL(in: data)
        try Task.checkCancellation()
        return StockMediaHit(
            id: "pixabay-video-\(id)", kind: .video, title: nil, url: fileURL.absoluteString,
            thumbnailURL: nil, creator: nil, creatorURL: nil,
            license: "Pixabay Content License", licenseURL: "https://pixabay.com/service/license-summary/",
            providerID: "pixabay", landingPageURL: MediaImportInput.provenanceURL(pageURL),
            width: nil, height: nil, durationSeconds: nil, fileSizeBytes: nil, attributionText: "Video via Pixabay"
        )
    }

    @concurrent static func fetchVideoPage(_ pageURL: URL) async throws -> Data {
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 20
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StockMediaError.undecodable(provider: "Pixabay") }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError("Pixabay page returned HTTP \(http.statusCode). Add a free Pixabay API key in Settings to resolve this video page, then retry the same link.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw ToolError("Pixabay video page exceeds the 2 MiB metadata limit") }
            data.append(byte)
        }
        return data
    }

    @concurrent static func videoURL(in data: Data) async throws -> URL {
        guard data.count <= 2 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else {
            throw StockMediaError.undecodable(provider: "Pixabay")
        }
        for script in try matches(#"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#, in: html) {
            if let json = try? JSONSerialization.jsonObject(with: Data(script.utf8)),
               let url = videoObjectURL(json, depth: 0) { return url }
        }
        for tag in try matches(#"(<meta\b[^>]*>)"#, in: html) {
            let fields = try attributes(in: tag)
            if ["og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream"].contains(fields["property"] ?? fields["name"] ?? ""),
               let url = mediaURL(fields["content"]) { return url }
        }
        if let video = try matches(#"(<video\b[^>]*>[\s\S]*?</video>)"#, in: html).first {
            for tag in try matches(#"(<(?:video|source)\b[^>]*>)"#, in: video) {
                if let url = mediaURL(try attributes(in: tag)["src"]) { return url }
            }
        }
        throw ToolError("Pixabay did not expose a downloadable video in this page. Add a free Pixabay API key in Settings, then retry the same link.")
    }

    private static func videoObjectURL(_ value: Any, depth: Int) -> URL? {
        guard depth < 16 else { return nil }
        if let objects = value as? [Any] {
            return objects.lazy.compactMap { videoObjectURL($0, depth: depth + 1) }.first
        }
        guard let object = value as? [String: Any] else { return nil }
        let types = (object["@type"] as? [String]) ?? [object["@type"] as? String ?? ""]
        if types.contains("VideoObject"), let url = mediaURL(object["contentUrl"] as? String) { return url }
        if let graph = object["@graph"] { return videoObjectURL(graph, depth: depth + 1) }
        return nil
    }

    private static func mediaURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw.replacingOccurrences(of: "&amp;", with: "&")),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.host?.isEmpty == false, url.pathExtension.lowercased() == "mp4" else { return nil }
        return url
    }

    private static func attributes(in tag: String) throws -> [String: String] {
        let regex = try NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive)
        var fields: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            if let name = Range(match.range(at: 1), in: tag), let value = Range(match.range(at: 2), in: tag) {
                fields[String(tag[name]).lowercased()] = String(tag[value])
            }
        }
        return fields
    }

    private static func matches(_ pattern: String, in html: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }
}
