import Foundation
import Testing
@testable import CompositorPro

struct ShotCandidateBundleTests {
    private func libraryAsset(
        id: String = "asset-1",
        name: String = "Harbor",
        type: ClipType = .video,
        duration: Double = 12,
        readiness: LibraryShotAsset.Readiness = .ready
    ) -> LibraryShotAsset {
        LibraryShotAsset(id: id, name: name, type: type, durationSeconds: duration, readiness: readiness)
    }

    private func remoteHit(
        id: String = "pixabay-video-1",
        url: String = "https://cdn.pixabay.com/video/harbor.mp4",
        duration: Int? = 12
    ) -> StockMediaHit {
        StockMediaHit(
            id: id,
            kind: .video,
            title: "harbor, sunset",
            url: url,
            thumbnailURL: "https://cdn.pixabay.com/video/harbor.jpg",
            creator: "Example Filmmaker",
            creatorURL: nil,
            license: "Pixabay Content License",
            licenseURL: "https://pixabay.com/service/license-summary/",
            providerID: "pixabay",
            landingPageURL: "https://pixabay.com/videos/harbor-1/",
            width: 1280,
            height: 720,
            durationSeconds: duration,
            fileSizeBytes: 10,
            attributionText: "Video by Example Filmmaker via Pixabay"
        )
    }

    @Test func readyLibraryEvidenceOutranksRemoteCatalog() {
        let visual = [ShotCandidateBuilder.VisualInput(assetID: "asset-1", startSeconds: 1.2345, endSeconds: 4.5, score: 0.2)]
        let spoken = [ShotCandidateBuilder.SpokenInput(assetID: "asset-1", startSeconds: 5, endSeconds: 8, text: "harbor at dusk")]
        let bundle = ShotCandidateBuilder.build(
            kind: .video,
            visual: visual,
            spoken: spoken,
            remote: [remoteHit()],
            assets: ["asset-1": libraryAsset()],
            limit: 8
        )

        #expect(bundle.candidates.count == 3)
        #expect(bundle.candidates.map(\.id) == [
            "library:asset-1:visual:1.235-4.5",
            "library:asset-1:spoken:5.0-8.0",
            "stock:pixabay:pixabay-video-1",
        ])
        #expect(bundle.candidates.map(\.rank) == [1, 2, 3])
        #expect(bundle.candidates[0].mediaRef == "asset-1")
        #expect(bundle.candidates[0].score == 0.2)
        #expect(bundle.candidates[1].title == "harbor at dusk")
        #expect(bundle.candidates[1].score == nil)
        #expect(bundle.candidates[2].url == "https://cdn.pixabay.com/video/harbor.mp4")
        #expect(bundle.candidates[2].attribution == "Video by Example Filmmaker via Pixabay")
        #expect(bundle.skipped.isEmpty)
        #expect(bundle.droppedUsable == 0)
    }

    @Test func distinctSourceSpansShareInputIdentityAndStockOriginSurvivesReceipt() {
        var asset = libraryAsset()
        asset.inputId = "sha256:one-input"
        asset.inputIdentityState = "verified"
        let bundle = ShotCandidateBuilder.build(kind: .video, visual: [
            .init(assetID: asset.id, startSeconds: 0, endSeconds: 2, score: 0.9),
            .init(assetID: asset.id, startSeconds: 4, endSeconds: 6, score: 0.8),
        ], spoken: [], remote: [remoteHit()], assets: [asset.id: asset], limit: 8)
        #expect(bundle.candidates[0].id != bundle.candidates[1].id)
        #expect(bundle.candidates[0].inputId == bundle.candidates[1].inputId)
        #expect(bundle.candidates[0].receipt()["inputIdentityState"] as? String == "verified")
        #expect(bundle.candidates[2].origin == remoteHit().origin)
        #expect((remoteHit().receipt["origin"] as? [String: Any])?["sourceId"] as? String == remoteHit().origin.sourceId)
    }

    @Test func unavailableLibraryAssetsAreSkippedWithReasons() {
        let visual = [
            ShotCandidateBuilder.VisualInput(assetID: "asset-missing", startSeconds: 0, endSeconds: 2, score: 0.9),
            ShotCandidateBuilder.VisualInput(assetID: "asset-failed", startSeconds: 2, endSeconds: 4, score: 0.9),
            ShotCandidateBuilder.VisualInput(assetID: "asset-pending", startSeconds: 4, endSeconds: 6, score: 0.9),
            ShotCandidateBuilder.VisualInput(assetID: "asset-empty-span", startSeconds: 6, endSeconds: 6, score: 0.9),
        ]
        let assets = [
            "asset-failed": libraryAsset(id: "asset-failed", readiness: .failed("test")),
            "asset-pending": libraryAsset(id: "asset-pending", readiness: .pending("downloading")),
            "asset-empty-span": libraryAsset(id: "asset-empty-span"),
        ]
        let bundle = ShotCandidateBuilder.build(
            kind: .video, visual: visual, spoken: [], remote: [], assets: assets, limit: 8
        )

        #expect(bundle.candidates.isEmpty)
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("removed after indexing") })
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("failed: test") })
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("still downloading") })
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("empty source span") })
    }

    @Test func remoteRowsRequireLicenseAttributionAndHTTPS() {
        var insecure = remoteHit(id: "pixabay-video-insecure", url: "http://cdn.pixabay.com/video.mp4")
        insecure = StockMediaHit(
            id: insecure.id, kind: insecure.kind, title: insecure.title, url: insecure.url,
            thumbnailURL: insecure.thumbnailURL, creator: insecure.creator, creatorURL: insecure.creatorURL,
            license: insecure.license, licenseURL: insecure.licenseURL, providerID: insecure.providerID,
            landingPageURL: insecure.landingPageURL, width: insecure.width, height: insecure.height,
            durationSeconds: insecure.durationSeconds, fileSizeBytes: insecure.fileSizeBytes, attributionText: insecure.attributionText
        )
        var unlicensed = remoteHit(id: "pixabay-video-unlicensed")
        unlicensed = StockMediaHit(
            id: unlicensed.id, kind: unlicensed.kind, title: unlicensed.title, url: unlicensed.url,
            thumbnailURL: unlicensed.thumbnailURL, creator: unlicensed.creator, creatorURL: unlicensed.creatorURL,
            license: "", licenseURL: unlicensed.licenseURL, providerID: unlicensed.providerID,
            landingPageURL: unlicensed.landingPageURL, width: unlicensed.width, height: unlicensed.height,
            durationSeconds: unlicensed.durationSeconds, fileSizeBytes: unlicensed.fileSizeBytes, attributionText: ""
        )
        let bundle = ShotCandidateBuilder.build(
            kind: .video, visual: [], spoken: [], remote: [insecure, unlicensed],
            assets: [:], limit: 8
        )

        #expect(bundle.candidates.isEmpty)
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("HTTPS") })
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("license or attribution") })
    }

    @Test func limitsReportTheOmittedUsableCount() {
        let spoken = (0..<3).map {
            ShotCandidateBuilder.SpokenInput(assetID: "asset-\($0)", startSeconds: Double($0), endSeconds: Double($0) + 1, text: "harbor")
        }
        let assets = Dictionary(uniqueKeysWithValues: (0..<3).map {
            ("asset-\($0)", libraryAsset(id: "asset-\($0)"))
        })
        let bundle = ShotCandidateBuilder.build(
            kind: .video, visual: [], spoken: spoken, remote: [], assets: assets, limit: 2
        )

        #expect(bundle.candidates.count == 2)
        #expect(bundle.droppedUsable == 1)
        #expect(bundle.candidates.map(\.rank) == [1, 2])
    }

    @Test func stockReceiptsPreserveDimensionsAndPreviewProvenance() throws {
        let bundle = ShotCandidateBuilder.build(
            kind: .video, visual: [], spoken: [], remote: [remoteHit()], assets: [:], limit: 8
        )
        let receipt = try #require(bundle.candidates.first).receipt()
        #expect(receipt["width"] as? Int == 1280)
        #expect(receipt["height"] as? Int == 720)
        #expect(receipt["thumbnailUrl"] as? String == "https://cdn.pixabay.com/video/harbor.jpg")
        #expect(receipt["landingPageUrl"] as? String == "https://pixabay.com/videos/harbor-1/")
    }

    @Test(arguments: [(1920, 1080), (0, -1)])
    func localReceiptsUseOnlyPositiveCachedDimensions(width: Int, height: Int) throws {
        var asset = libraryAsset()
        asset.width = width
        asset.height = height
        let bundle = ShotCandidateBuilder.build(
            kind: .video,
            visual: [.init(assetID: asset.id, startSeconds: 0, endSeconds: 1, score: 0.5)],
            spoken: [.init(assetID: asset.id, startSeconds: 1, endSeconds: 2, text: "Harbor")],
            remote: [], assets: [asset.id: asset], limit: 8
        )
        #expect(bundle.candidates.count == 2)
        for candidate in bundle.candidates {
            let receipt = candidate.receipt()
            #expect(receipt["width"] as? Int == (width > 0 ? width : nil))
            #expect(receipt["height"] as? Int == (height > 0 ? height : nil))
            #expect(receipt["thumbnailUrl"] == nil)
        }
    }

    @Test func exactDuplicateCandidatesAreReportedOnce() {
        let visual = [
            ShotCandidateBuilder.VisualInput(assetID: "asset-1", startSeconds: 1, endSeconds: 2, score: 0.5),
            ShotCandidateBuilder.VisualInput(assetID: "asset-1", startSeconds: 1, endSeconds: 2, score: 0.9),
        ]
        let bundle = ShotCandidateBuilder.build(
            kind: .video, visual: visual, spoken: [], remote: [],
            assets: ["asset-1": libraryAsset()], limit: 8
        )

        #expect(bundle.candidates.count == 1)
        #expect(bundle.candidates.first?.score == 0.5)
        #expect(bundle.skipped.map(\.reason).contains { $0.contains("Duplicate candidate") })
    }
}
