import Foundation
import Testing
@testable import PalmierPro

// Exercises the real HTTP path (fetch → decode → map → resolve URL) against the local
// gallery servers. Skips cleanly when they aren't running, so it's safe in CI.
@Suite("GalleryProvider (live)")
struct GalleryProviderLiveTests {

    private var downloads: GalleryProvider {
        AssetProviderRegistry.provider("downloads") as! GalleryProvider
    }

    @Test func liveListAndStreamHead() async throws {
        guard await downloads.health() else {
            print("skip: downloads gallery (:4617) not running")
            return
        }
        let result = try await downloads.list(.video, query: ListQuery(keys: [], page: 1, limit: 5))
        #expect(!result.items.isEmpty)
        let card = try #require(result.items.first)
        #expect(card.type == .video)
        #expect(card.ref.hasPrefix("/media/"))

        // The resolved URL must stream bytes with Range support.
        let url = try #require(downloads.fetchURL(forRef: card.ref))
        var req = URLRequest(url: url)
        req.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 206 || http.statusCode == 200)
        #expect(!data.isEmpty)
        print("live: downloads returned \(result.items.count) card(s); first=\(card.name); streamed \(data.count) bytes")
    }

    @Test func liveKeywordFilterNarrows() async throws {
        guard await downloads.health() else {
            print("skip: downloads gallery (:4617) not running")
            return
        }
        let all = try await downloads.list(.video, query: ListQuery(keys: [], page: 1, limit: 100))
        let narrowed = try await downloads.list(.video, query: ListQuery(keys: ["douyin"], page: 1, limit: 100))
        #expect(narrowed.items.count <= all.items.count)
    }
}
