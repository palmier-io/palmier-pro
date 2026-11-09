import Foundation
import Testing
@testable import CompositorPro

@Suite("Stock delivery history")
struct StockDeliveryHistoryTests {
    @Test("Bounded history caps entries at maximum limit")
    func capsEntriesAtMaximum() {
        var history = StockDeliveryHistory()
        for i in 0..<60 {
            history.add(sourceIds: ["source:\(i)"], outputFilename: "output_\(i).mp4")
        }
        #expect(history.entries.count == StockDeliveryHistory.maximumEntries)
        #expect(history.entries.last?.outputFilename == "output_59.mp4")
        #expect(!history.contains("source:0"))
        #expect(history.contains("source:59"))
    }

    @Test("Used sources union all entries")
    func usedSourcesUnion() {
        var history = StockDeliveryHistory()
        history.add(sourceIds: ["s1", "s2"], outputFilename: "video1.mp4")
        history.add(sourceIds: ["s2", "s3"], outputFilename: "video2.mp4")
        #expect(history.usedSourceIds == Set(["s1", "s2", "s3"]))
        #expect(history.contains("s1"))
        #expect(history.contains("s3"))
        #expect(!history.contains("s4"))
    }

    @Test("Extracts canonical source IDs from media manifest")
    func extractsCanonicalSourceIds() {
        var manifest = MediaManifest()
        let origin = MediaImportOrigin(provider: "pexels", assetId: "12345", landingPageUrl: nil, sourceId: "stock:pexels:12345")
        let entry = MediaManifestEntry(
            id: "clip-1",
            name: "Clip 1",
            type: .video,
            source: .file(url: URL(fileURLWithPath: "/tmp/sample.mp4")),
            duration: 5.0,
            importInput: MediaImportInput(origin: origin)
        )
        manifest.entries.append(entry)

        let ids = StockDeliveryHistory.sourceIds(manifest: manifest)
        #expect(ids.contains("stock:pexels:12345"))
    }
}
