import Foundation
import Testing
@testable import CompositorPro

@Suite("Source diversity")
struct SourceDiversityTests {
    private func candidate(_ id: String, _ provider: String, _ title: String) -> SourceDiversity.Candidate {
        SourceDiversity.Candidate(id: id, providerID: provider, title: title, url: "https://cdn.example/\(id).mp4")
    }

    @Test func providersAreInterleavedRatherThanClumped() {
        let pixabayTitles = ["Harbor boat", "Mountain trail", "City night", "Forest fog"]
        let pexelsTitles = ["Desert dune", "Ocean cliff"]
        let pool = pixabayTitles.enumerated().map { candidate("pix-\($0.offset)", "pixabay", $0.element) }
            + pexelsTitles.enumerated().map { candidate("pex-\($0.offset)", "pexels", $0.element) }
        let selection = SourceDiversity.select(pool, limit: 4)
        #expect(selection.picked.count == 4)
        #expect(Set(selection.picked.prefix(2).map(\.providerID)) == ["pexels", "pixabay"])
    }

    @Test func duplicatesAndDeliveredSourcesAreSkipped() {
        var delivered = StockDeliveryHistory()
        delivered.add(sourceIds: ["pix-1"], outputFilename: "final-cut-01")
        let pool = [
            candidate("pix-0", "pixabay", "Harbor boat"),
            candidate("pix-0", "pixabay", "Harbor boat"),
            candidate("pix-1", "pixabay", "Harbor boat"),
        ]
        let selection = SourceDiversity.select(pool, delivered: delivered, limit: 5)
        #expect(selection.picked.map(\.id) == ["pix-0"])
        #expect(selection.skipped.map(\.reason) == ["duplicate_id", "already_delivered"])
    }

    @Test func nearDuplicateSubjectsAreRejected() {
        let pool = [
            candidate("a", "pixabay", "Sunset harbor boats"),
            candidate("b", "pexels", "Sunset harbor boats again"),
            candidate("c", "pexels", "Mountain trail runner"),
        ]
        let selection = SourceDiversity.select(pool, limit: 5)
        #expect(selection.picked.map(\.id) == ["a", "c"])
        #expect(selection.skipped.contains { $0.id == "b" && $0.reason == "near_duplicate_subject" })
    }

    @Test func limitZeroOrEmptyPoolYieldsNothing() {
        #expect(SourceDiversity.select([], limit: 3).picked.isEmpty)
        let bounded = SourceDiversity.select([candidate("a", "pixabay", "One")], limit: 0)
        #expect(bounded.picked.isEmpty)
        #expect(bounded.receipt["pickedCount"] as? Int == 0)
    }
}
