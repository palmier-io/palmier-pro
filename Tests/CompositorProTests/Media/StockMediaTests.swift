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

    @Test func pexelsIsTheOnlyVideoSource() {
        #expect(PexelsProvider().supportedKinds.contains(.video))
        #expect(!OpenverseProvider().supportedKinds.contains(.video))
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
        {"results":[{"id":"1","url":"https://cdn.freesound.org/a.mp3","duration":300804,\
        "license":"by","license_version":"4.0","mature":false}]}
        """
        let response = try JSONDecoder().decode(OpenverseProvider.Response.self, from: Data(json.utf8))
        #expect(response.results.first?.duration == 300_804)
    }
}
