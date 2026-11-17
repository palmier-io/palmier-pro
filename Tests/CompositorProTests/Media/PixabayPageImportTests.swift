import Foundation
import Testing
@testable import CompositorPro

@Suite("Pixabay video page resolution")
struct PixabayPageImportTests {
    static let page = URL(string: "https://pixabay.com/videos/business-office-contemporary-136268/")!

    @Test(arguments: [
        "https://pixabay.com/videos/business-office-contemporary-136268/",
        "https://www.pixabay.com/en/videos/business-office-contemporary-136268/?ref=share",
    ])
    func acceptsOriginalVideoPages(url: String) {
        #expect(PixabayProvider.videoID(from: URL(string: url)!) == 136268)
    }

    @Test(arguments: [
        "https://pixabay.com.evil.test/videos/office-136268/", "http://pixabay.com/videos/office-136268/",
        "https://user:secret@pixabay.com/videos/office-136268/", "https://pixabay.com/videos/office-0/",
        "https://pixabay.com/videos/office-999999999999999999999999999999999/",
        "https://pixabay.com/images/office-136268/", "https://pixabay.com/videos/office/",
    ])
    func rejectsInvalidPages(url: String) {
        #expect(PixabayProvider.videoID(from: URL(string: url)!) == nil)
    }

    @Test func resolvesTheExactIDWithTheConfiguredKey() async throws {
        let provider = PixabayProvider(apiKey: "fixture-key", requestJSON: { url, _ in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.contains(.init(name: "id", value: "136268")) == true)
            #expect(items?.contains(.init(name: "key", value: "fixture-key")) == true)
            return Data(#"{"totalHits":1,"hits":[{"id":136268,"videos":{"medium":{"url":"https://cdn.pixabay.com/video/office.mp4","width":1280,"height":720}}}]}"#.utf8)
        }, requestPage: { _ in
            Issue.record("A configured exact lookup must not scrape the page")
            throw CancellationError()
        })
        let hit = try await provider.resolveVideoPage(Self.page)
        #expect(hit.id == "pixabay-video-136268")
        #expect(hit.url == "https://cdn.pixabay.com/video/office.mp4")
    }

    @Test func refusesAnAPIResultForADifferentVideo() async {
        let provider = PixabayProvider(apiKey: "fixture-key", requestJSON: { _, _ in
            Data(#"{"totalHits":1,"hits":[{"id":42,"videos":{"medium":{"url":"https://cdn.pixabay.com/other.mp4","width":1280,"height":720}}}]}"#.utf8)
        })
        await #expect(throws: ToolError.self) { _ = try await provider.resolveVideoPage(Self.page) }
    }

    @Test(arguments: [
        #"<script type="application/ld+json">{"@graph":[{"@type":"VideoObject","contentUrl":"https://cdn.pixabay.com/video/office.mp4"}]}</script>"#,
        #"<meta content='https://cdn.pixabay.com/video/office.mp4' property='og:video:secure_url'>"#,
        #"<video poster='preview.jpg'><source type='video/mp4' src='https://cdn.pixabay.com/video/office.mp4'></video>"#,
    ])
    func resolvesPublishedMetadataWithoutAKey(html: String) async throws {
        let provider = PixabayProvider(apiKey: "", requestJSON: { _, _ in
            Issue.record("Keyless page import must not invoke the keyed API")
            throw CancellationError()
        }, requestPage: { _ in Data(html.utf8) })
        let hit = try await provider.resolveVideoPage(Self.page)
        #expect(hit.url == "https://cdn.pixabay.com/video/office.mp4")
        #expect(hit.origin.sourceId == "stock:pixabay:pixabay-video-136268")
        #expect(hit.landingPageURL == Self.page.absoluteString)
    }

    @Test(arguments: [
        #"<a href='https://cdn.pixabay.com/unrelated.mp4'>Related video</a>"#,
        #"<script type='application/ld+json'>{"@type":"VideoObject","contentUrl":"http://cdn.pixabay.com/video.mp4"}</script>"#,
        #"<video src='https://user:secret@cdn.pixabay.com/video.mp4'></video>"#,
        "<html>Access denied</html>",
    ])
    func refusesMissingOrInvalidVideoMetadata(html: String) async {
        await #expect(throws: ToolError.self) { _ = try await PixabayProvider.videoURL(in: Data(html.utf8)) }
    }
}
