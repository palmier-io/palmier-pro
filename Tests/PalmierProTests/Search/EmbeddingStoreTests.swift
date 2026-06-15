import Foundation
import Testing
@testable import PalmierPro

@Suite("EmbeddingStore")
struct EmbeddingStoreTests {
    @Test func roundTrip() throws {
        let key = "test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }

        let dim = 16
        let header = EmbeddingStore.Header(model: "test-model", modelVersion: 1, samplerVersion: 1, dim: dim, count: 3)
        let rows = [
            EmbeddingStore.Row(time: 1.25, shotStart: 0, shotEnd: 4.5),
            EmbeddingStore.Row(time: 6.0, shotStart: 4.5, shotEnd: 9.0),
            EmbeddingStore.Row(time: 12.5, shotStart: 9.0, shotEnd: 20.0),
        ]
        let vectors = (0..<(3 * dim)).map { Float($0) / 10 }
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: key)

        let loaded = try EmbeddingStore.load(key: key)
        #expect(loaded.header == header)
        #expect(loaded.rows.count == 3)
        #expect(loaded.rows[1].time == 6.0)
        #expect(loaded.rows[2].shotEnd == 20.0)
        for i in 0..<vectors.count {
            #expect(abs(loaded.vectors[i] - vectors[i]) < 0.01)
        }

        #expect(EmbeddingStore.isCurrent(key: key, model: "test-model", modelVersion: 1, samplerVersion: 1))
        #expect(!EmbeddingStore.isCurrent(key: key, model: "test-model", modelVersion: 2, samplerVersion: 1))
        #expect(!EmbeddingStore.isCurrent(key: key, model: "test-model", modelVersion: 1, samplerVersion: 2))
    }

    @Test func missingAndCorrupt() throws {
        #expect(EmbeddingStore.header(key: "nonexistent") == nil)
        let key = "corrupt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        try Data("not an embed file".utf8).write(to: EmbeddingStore.diskURL(key))
        #expect(EmbeddingStore.header(key: key) == nil)
        #expect(throws: (any Error).self) { try EmbeddingStore.load(key: key) }
    }
}
