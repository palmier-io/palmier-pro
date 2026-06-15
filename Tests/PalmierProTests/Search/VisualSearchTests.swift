import Foundation
import Testing
@testable import PalmierPro

@Suite("VisualSearch")
struct VisualSearchTests {
    static func index(vectors: [[Float]], shots: [(Double, Double, Double)]) -> EmbeddingStore.AssetIndex {
        EmbeddingStore.AssetIndex(
            header: .init(model: "test", modelVersion: 1, samplerVersion: 1, dim: vectors[0].count, count: vectors.count),
            rows: shots.map { .init(time: $0.0, shotStart: $0.1, shotEnd: $0.2) },
            vectors: vectors.flatMap { $0 }
        )
    }

    @Test func ranksAndCutsOff() {
        let idx = Self.index(
            vectors: [[1, 0, 0], [0.9, 0.1, 0], [0, 1, 0], [0, 0, 1]],
            shots: [(1, 0, 4), (5, 4, 8), (9, 8, 12), (13, 12, 16)]
        )
        let hits = VisualSearch.search(query: [1, 0, 0], indexes: [("a", idx)])
        #expect(hits.first?.time == 1)
        #expect(hits.first?.score == 1)
        // Orthogonal vectors fall below the relative cutoff.
        #expect(!hits.contains { $0.time == 9 || $0.time == 13 })
    }

    @Test func bestPerShotDedupes() {
        let idx = Self.index(
            vectors: [[1, 0, 0], [0.99, 0.01, 0], [0.5, 0.5, 0]],
            shots: [(1, 0, 10), (5, 0, 10), (9, 0, 10)]
        )
        let hits = VisualSearch.search(query: [1, 0, 0], indexes: [("a", idx)])
        #expect(hits.count == 1)
        #expect(hits.first?.time == 1)
    }

    @Test func mergesAcrossAssets() {
        let a = Self.index(vectors: [[1, 0, 0]], shots: [(1, 0, 2)])
        let b = Self.index(vectors: [[0.95, 0.05, 0]], shots: [(3, 2, 4)])
        let hits = VisualSearch.search(query: [1, 0, 0], indexes: [("a", a), ("b", b)])
        #expect(hits.map(\.assetID) == ["a", "b"])
    }

    @Test func emptyAndMismatchedDims() {
        let idx = Self.index(vectors: [[1, 0]], shots: [(1, 0, 2)])
        #expect(VisualSearch.search(query: [1, 0, 0], indexes: [("a", idx)]).isEmpty)
        #expect(VisualSearch.search(query: [1, 0], indexes: []).isEmpty)
    }

    @Test func cosineFloorDropsWeakTopMatch() {
        // A weak best-of-a-bad-batch (cos 0.04) is dropped entirely — the false-positive fix.
        let weak = Self.index(vectors: [[0.04, 0, 0]], shots: [(1, 0, 2)])
        #expect(VisualSearch.search(query: [1, 0, 0], indexes: [("a", weak)], minScore: 0.05).isEmpty)
        // Without a floor the relative cutoff still surfaces it.
        #expect(VisualSearch.search(query: [1, 0, 0], indexes: [("a", weak)]).count == 1)
        // A real match clears the floor.
        let strong = Self.index(vectors: [[0.5, 0, 0]], shots: [(1, 0, 2)])
        #expect(VisualSearch.search(query: [1, 0, 0], indexes: [("a", strong)], minScore: 0.05).count == 1)
    }
}
