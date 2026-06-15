import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PalmierPro

/// End-to-end: fixture video → sample → embed → store → text query ranks the right shot.
/// Requires Phase-0 artifacts; skipped otherwise.
@Suite("VisualIndexer e2e", .serialized)
struct VisualIndexerTests {
    @Test(.enabled(if: VisualEmbedderParityTests.artifactsExist)) func indexesStillImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).png")
        try Self.writePNG(to: url)
        let key = try #require(EmbeddingStore.key(for: url))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
        }

        let model = try await VisualEmbedderParityTests.loadModel()
        try await VisualIndexer.indexImage(url: url, model: model)
        #expect(!VisualIndexer.needsIndex(url: url, spec: model.spec))

        let index = try EmbeddingStore.load(key: key)
        #expect(index.rows.count == 1)
        #expect(index.rows.first?.shotStart == 0 && index.rows.first?.shotEnd == 0)
        #expect(index.vectors.count == model.spec.embeddingDim)
    }

    static func writePNG(to url: URL) throws {
        let size = 64
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "VisualIndexerTests", code: 1) }
        ctx.setFillColor(CGColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "VisualIndexerTests", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "VisualIndexerTests", code: 3) }
    }

    @Test(.enabled(if: VisualEmbedderParityTests.artifactsExist)) func undecodableFileGetsEmptyIndex() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: url)
        let key = try #require(EmbeddingStore.key(for: url))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
        }

        let model = try await VisualEmbedderParityTests.loadModel()
        try await VisualIndexer.index(url: url, duration: 5, model: model)
        #expect(!VisualIndexer.needsIndex(url: url, spec: model.spec))
        #expect(try EmbeddingStore.load(key: key).rows.isEmpty)
    }

    @Test(.enabled(if: VisualEmbedderParityTests.artifactsExist)) func indexAndSearchFixture() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (30, 30, 220), seconds: 10),
            .init(rgb: (220, 30, 30), seconds: 10),
            .init(rgb: (30, 200, 30), seconds: 10),
        ])
        let key = try #require(EmbeddingStore.key(for: url))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
        }

        let model = try await VisualEmbedderParityTests.loadModel()
        #expect(VisualIndexer.needsIndex(url: url, spec: model.spec))
        try await VisualIndexer.index(url: url, duration: 30, model: model)
        #expect(!VisualIndexer.needsIndex(url: url, spec: model.spec))

        let index = try EmbeddingStore.load(key: key)
        #expect(index.header.dim == model.spec.embeddingDim)
        #expect(index.rows.count >= 3)

        // "a red image" should hit a frame whose shot is the middle (red) scene.
        let query = try model.encode(text: "a plain solid red image")
        let dim = index.header.dim
        var best = (score: -Float.infinity, row: 0)
        for i in 0..<index.rows.count {
            var dot: Float = 0
            for d in 0..<dim { dot += query[d] * index.vectors[i * dim + d] }
            if dot > best.score { best = (dot, i) }
        }
        let hit = index.rows[best.row]
        #expect(hit.time >= 9 && hit.time < 21, "top hit at \(hit.time)s, expected red scene (10–20s)")
        #expect(hit.shotStart >= 7.5 && hit.shotEnd <= 22.5, "shot range \(hit.shotStart)–\(hit.shotEnd)")
    }
}
