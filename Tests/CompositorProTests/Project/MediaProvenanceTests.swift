import Foundation
import Testing
@testable import CompositorPro

@Suite("Stock media provenance")
@MainActor
struct MediaProvenanceTests {
    private func stockAsset() -> MediaAsset {
        let origin = MediaImportOrigin(
            provider: "pexels",
            assetId: "asset-42",
            landingPageURL: "https://www.pexels.com/video/asset-42",
            creator: "R. Okafor",
            license: "Pexels License",
            attribution: "Video by R. Okafor (Pexels)")
        var input = MediaImportInput()
        input.origin = origin
        input.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = MediaAsset(id: "asset-42", url: URL(fileURLWithPath: "/tmp/harbor.mp4"),
                               type: .video, name: "Harbor")
        asset.importInput = input
        return asset
    }

    @Test func manifestEntryKeepsTheStockCredit() throws {
        let entry = stockAsset().toManifestEntry(projectURL: nil)
        #expect(entry.providerAssetId == "asset-42")
        #expect(entry.providerLandingURL == "https://www.pexels.com/video/asset-42")
        #expect(entry.providerCreator == "R. Okafor")
        #expect(entry.providerLicense == "Pexels License")
        #expect(entry.providerAttribution == "Video by R. Okafor (Pexels)")
        #expect(entry.providerRetrievalDate == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func manifestEntryIsStableAcrossReads() {
        let asset = stockAsset()
        let first = asset.toManifestEntry(projectURL: nil)
        let second = asset.toManifestEntry(projectURL: nil)
        #expect(first == second)
    }

    @Test func localMediaCarriesNoStockCredit() {
        let asset = MediaAsset(id: "local-1", url: URL(fileURLWithPath: "/tmp/local.mp4"),
                               type: .video, name: "Local")
        let entry = asset.toManifestEntry(projectURL: nil)
        #expect(entry.providerAssetId == nil)
        #expect(entry.providerCreator == nil)
        #expect(entry.providerRetrievalDate == nil)
    }

    @Test func originReceiptCarriesTheCredit() {
        let origin = MediaImportOrigin(provider: "pixabay", assetId: "9", creator: "A. Silva",
                                       license: "CC0", attribution: "Free video by A. Silva")
        let receipt = origin.receipt
        #expect(receipt["creator"] as? String == "A. Silva")
        #expect(receipt["license"] as? String == "CC0")
        #expect(receipt["attribution"] as? String == "Free video by A. Silva")
        #expect(receipt["sourceId"] as? String == "stock:pixabay:9")
    }

    @Test func originRoundTripsThroughItsCodableForm() throws {
        let origin = MediaImportOrigin(provider: "openverse", assetId: "3", landingPageURL: "https://example.com/3",
                                       creator: "K. Ito", license: "CC BY 4.0", attribution: "K. Ito / CC BY 4.0")
        let data = try JSONEncoder().encode(origin)
        let decoded = try JSONDecoder().decode(MediaImportOrigin.self, from: data)
        #expect(decoded == origin)
    }
}
