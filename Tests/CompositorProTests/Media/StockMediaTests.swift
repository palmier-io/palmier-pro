import Foundation
import Testing
@testable import CompositorPro

struct StockMediaTests {
    private func file(
        quality: String? = "hd",
        type: String? = "video/mp4",
        width: Int? = 1920,
        height: Int? = 1080
    ) -> PexelsProvider.VideoResponse.File {
        .init(quality: quality, file_type: type, width: width, height: height, link: "https://videos.pexels.com/a.mp4")
    }

    @Test func openverseNeedsNoKeyAndCoversImagesAndAudio() {
        let provider = OpenverseProvider()
        #expect(provider.supportedKinds == [.image, .audio])
        #expect(!provider.supportedKinds.contains(.video))
    }

    @Test func pexelsOffersVideoAndPhotography() {
        #expect(PexelsProvider().supportedKinds == [.image, .video])
    }

    @Test func pixabayOffersVideoWithoutKeylessImageOrAudioSupport() {
        #expect(PixabayProvider().supportedKinds == [.video])
    }

    @Test func providerOutcomesKeepTheirDisplayNames() {
        let outcome = StockProviderOutcome(
            id: "pixabay",
            displayName: "Pixabay",
            status: .needsAPIKey,
            count: 0,
            message: "Pixabay needs a free API key."
        )
        #expect(outcome.receipt["displayName"] as? String == "Pixabay")
    }

    @Test func pixabayRequestUsesKeySafeSearchAndDocumentedPageBounds() throws {
        let query = StockMediaQuery(text: "harbor & sunset", kind: .video, orientation: nil, maxDurationSeconds: nil, limit: 1)
        let url = try #require(PixabayProvider.searchURL(query, key: "key-1"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
        #expect(values["key"] == "key-1")
        #expect(values["q"] == "harbor & sunset")
        #expect(values["per_page"] == "3")
        #expect(values["page"] == "1")
        #expect(values["safesearch"] == "true")
    }

    @Test func pixabayPrefersDocumentedMediumFile() {
        let files = [
            "tiny": PixabayProvider.VideoResponse.Rendition(url: "https://cdn.pixabay.com/tiny.mp4", width: 640, height: 360, size: 1, thumbnail: nil),
            "medium": PixabayProvider.VideoResponse.Rendition(url: "https://cdn.pixabay.com/medium.mp4", width: 1280, height: 720, size: 10, thumbnail: "https://cdn.pixabay.com/medium.jpg"),
            "large": PixabayProvider.VideoResponse.Rendition(url: "https://cdn.pixabay.com/large.mp4", width: 3840, height: 2160, size: 100, thumbnail: nil),
        ]
        #expect(PixabayProvider.bestRendition(files)?.url == "https://cdn.pixabay.com/medium.mp4")
    }

    @Test func pixabayFallsBackOnlyToDownloadableProgressiveFiles() {
        let files = [
            "large": PixabayProvider.VideoResponse.Rendition(url: "", width: 3840, height: 2160, size: 100, thumbnail: nil),
            "medium": PixabayProvider.VideoResponse.Rendition(url: "https://cdn.pixabay.com/medium.mp4", width: nil, height: nil, size: 10, thumbnail: nil),
            "tiny": PixabayProvider.VideoResponse.Rendition(url: "https://cdn.pixabay.com/tiny.mp4", width: 640, height: 360, size: 1, thumbnail: nil),
        ]
        #expect(PixabayProvider.bestRendition(files)?.url == "https://cdn.pixabay.com/tiny.mp4")
        #expect(PixabayProvider.bestRendition([:]) == nil)
    }

    @Test func pixabayMapsLicensesAttributionDimensionsAndDuration() throws {
        let response = try JSONDecoder().decode(PixabayProvider.VideoResponse.self, from: Data(
            """
            {"totalHits": 1, "hits": [{
              "id": 125,
              "pageURL": "https://pixabay.com/videos/id-125/",
              "tags": "harbor, sunset",
              "duration": 12,
              "videos": {"medium": {
                "url": "https://cdn.pixabay.com/video/medium.mp4",
                "width": 1280, "height": 720, "size": 10,
                "thumbnail": "https://cdn.pixabay.com/video/medium.jpg"
              }},
              "user": "Example Filmmaker"
            }]}
            """.utf8
        ))
        let query = StockMediaQuery(text: "harbor sunset", kind: .video, orientation: nil, maxDurationSeconds: 30, limit: 5)
        let hit = try #require(PixabayProvider.hit(response.hits[0], query: query))
        #expect(hit.id == "pixabay-video-125")
        #expect(hit.title == "harbor, sunset")
        #expect(hit.license == "Pixabay Content License")
        #expect(hit.licenseURL == "https://pixabay.com/service/license-summary/")
        #expect(hit.creator == "Example Filmmaker")
        #expect(hit.attribution == "Video by Example Filmmaker via Pixabay")
        #expect(hit.durationSeconds == 12)
        #expect(hit.width == 1280)
        #expect(hit.height == 720)

        let tooLong = StockMediaQuery(text: "harbor sunset", kind: .video, orientation: nil, maxDurationSeconds: 5, limit: 5)
        #expect(PixabayProvider.hit(response.hits[0], query: tooLong) == nil)
    }

    @Test func pixabayRejectsNonDownloadableLinksAndMissingCredentialsWithoutNetwork() async {
        await #expect(throws: StockMediaError.needsAPIKey(provider: "Pixabay")) {
            _ = try await PixabayProvider(apiKey: "").search(
                StockMediaQuery(text: "harbor", kind: .video, orientation: nil, maxDurationSeconds: nil, limit: 3)
            )
        }
        let bad = PixabayProvider.VideoResponse.Video(
            id: 1, pageURL: nil, tags: nil, duration: nil,
            videos: ["medium": PixabayProvider.VideoResponse.Rendition(
                url: "http://cdn.pixabay.com/medium.mp4", width: 1280, height: 720, size: 1, thumbnail: nil
            )],
            user: nil
        )
        let query = StockMediaQuery(text: "harbor", kind: .video, orientation: nil, maxDurationSeconds: nil, limit: 3)
        #expect(PixabayProvider.hit(bad, query: query) == nil)
    }

    @Test func bestFileSkipsStreamsAndPicksTheSmallestHD() {
        let chosen = PexelsProvider.bestFile([
            file(quality: "sd", width: 640, height: 338),
            file(quality: "hd", width: 4096, height: 2160),
            file(quality: "hd", width: 1920, height: 1080),
            file(quality: "hd", width: 3840, height: 2160),
        ])
        #expect(chosen?.width == 1920)
    }

    @Test func bestFileRejectsHLSEntriesThatCarryNoDimensions() {
        let chosen = PexelsProvider.bestFile([
            file(quality: "hls", type: "video/mp4", width: nil, height: nil),
        ])
        #expect(chosen == nil)
    }

    @Test func bestFileFallsBackToTheSmallestProgressiveWhenNoneAreHD() {
        let chosen = PexelsProvider.bestFile([
            file(quality: "sd", width: 1920, height: 1080),
            file(quality: "sd", width: 640, height: 338),
        ])
        #expect(chosen?.width == 640)
    }

    @Test func bestFileHandlesMissingAndEmptyLists() {
        #expect(PexelsProvider.bestFile(nil) == nil)
        #expect(PexelsProvider.bestFile([]) == nil)
    }

    @Test(arguments: [(width: 0, height: 1080), (width: -1, height: 1080),
                      (width: 1920, height: 0), (width: 1920, height: -1), (width: Int.max, height: 2)])
    func pexelsSkipsInvalidRenditionDimensions(dimensions: (width: Int, height: Int)) {
        let valid = file()
        let invalid = file(width: dimensions.width, height: dimensions.height)
        #expect(PexelsProvider.bestFile([invalid, valid]) == valid)
        #expect(PexelsProvider.bestFile([invalid]) == nil)
    }

    @Test(arguments: [(width: 0, height: 1080), (width: -1, height: 1080),
                      (width: 1920, height: 0), (width: 1920, height: -1), (width: Int.max, height: 2)])
    func pixabaySkipsInvalidPreferredAndFallbackRenditionDimensions(dimensions: (width: Int, height: Int)) {
        let valid = PixabayProvider.VideoResponse.Rendition(url: "https://example.test/valid.mp4",
            width: 1920, height: 1080, size: 10, thumbnail: nil)
        let invalid = PixabayProvider.VideoResponse.Rendition(url: "https://example.test/invalid.mp4",
            width: dimensions.width, height: dimensions.height, size: 1, thumbnail: nil)
        #expect(PixabayProvider.bestRendition(["medium": invalid, "tiny": valid]) == valid)
        #expect(PixabayProvider.bestRendition(["large": invalid, "tiny": valid]) == valid)
        #expect(PixabayProvider.bestRendition(["medium": invalid]) == nil)
    }

    @Test func representableMaximumPixelCountIsNotSilentlyClamped() {
        let pexels = file(width: Int.max, height: 1)
        #expect(PexelsProvider.bestFile([pexels]) == pexels)
        let pixabay = PixabayProvider.VideoResponse.Rendition(url: "https://example.test/max.mp4",
            width: Int.max, height: 1, size: nil, thumbnail: nil)
        #expect(PixabayProvider.bestRendition(["medium": pixabay]) == pixabay)
    }

    @Test func attributionPrefersTheSourcesOwnWording() {
        let supplied = StockMediaHit(
            id: "a", kind: .audio, title: nil, url: "https://x/y.mp3", thumbnailURL: nil,
            creator: "Someone", creatorURL: nil, license: "BY 4.0", licenseURL: nil,
            providerID: "openverse", landingPageURL: nil, width: nil, height: nil,
            durationSeconds: nil, fileSizeBytes: nil,
            attributionText: "\"Waves\" by Someone is licensed under CC BY 4.0."
        )
        #expect(supplied.attribution.hasPrefix("\"Waves\" by Someone"))

        let composed = StockMediaHit(
            id: "b", kind: .video, title: nil, url: "https://x/y.mp4", thumbnailURL: nil,
            creator: "Someone", creatorURL: "https://x/who", license: "Pexels License",
            licenseURL: "https://x/license", providerID: "pexels", landingPageURL: nil,
            width: nil, height: nil, durationSeconds: 12, fileSizeBytes: nil,
            attributionText: nil
        )
        #expect(composed.attribution == "Video by Someone — Pexels License (https://x/license)")
    }

    @Test func receiptCarriesEverythingNeededToImportAndCredit() throws {
        let hit = StockMediaHit(
            id: "pexels-video-1", kind: .video, title: nil, url: "https://videos.pexels.com/a.mp4",
            thumbnailURL: "https://images.pexels.com/a.jpg", creator: "Jo",
            creatorURL: "https://www.pexels.com/@jo", license: "Pexels License",
            licenseURL: "https://www.pexels.com/license/", providerID: "pexels",
            landingPageURL: "https://www.pexels.com/video/a-1/", width: 1920, height: 1080,
            durationSeconds: 9, fileSizeBytes: nil, attributionText: nil
        )
        let receipt = hit.receipt
        #expect(receipt["url"] as? String == "https://videos.pexels.com/a.mp4")
        #expect(receipt["license"] as? String == "Pexels License")
        #expect(receipt["creator"] as? String == "Jo")
        #expect(receipt["durationSeconds"] as? Int == 9)
        #expect(receipt["attribution"] != nil)
    }

    @Test func emptySearchTextIsRefused() async {
        await #expect(throws: StockMediaError.emptyQuery) {
            _ = try await StockMediaSearch.search(
                StockMediaQuery(text: "   ", kind: .image, orientation: nil, maxDurationSeconds: nil, limit: 5)
            )
        }
    }

    @Test func audioDurationIsConvertedFromMilliseconds() throws {
        // Openverse reports audio duration in milliseconds; a hit must not claim 300 seconds
        // of silence for a five-minute ambience bed.
        let json = """
        {"page":1,"page_count":1,"result_count":1,"results":[{"id":"1","url":"https://cdn.freesound.org/a.mp3","duration":300804,\
        "license":"by","license_version":"4.0","mature":false}]}
        """
        let response = try JSONDecoder().decode(OpenverseProvider.Response.self, from: Data(json.utf8))
        #expect(response.results.first?.duration == 300_804)
    }
}
