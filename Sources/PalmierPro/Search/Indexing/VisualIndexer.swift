import CoreGraphics
import Foundation
import ImageIO

/// Indexes one asset: sampled frames → embeddings → EmbeddingStore. Idempotent per (file, model, sampler).
enum VisualIndexer {
    static func needsIndex(url: URL, spec: VisualEmbedder.Spec) -> Bool {
        guard let key = EmbeddingStore.key(for: url) else { return false }
        return !EmbeddingStore.isCurrent(
            key: key, model: spec.model, modelVersion: spec.version,
            samplerVersion: FrameSampler.samplerVersion
        )
    }

    static func index(
        url: URL,
        duration: Double,
        model: VisualEmbedder,
        options: FrameSampler.Options = .init(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let key = EmbeddingStore.key(for: url) else { return }
        let spec = model.spec
        guard needsIndex(url: url, spec: spec) else { return }

        var times: [Double] = []
        var shotIndices: [Int] = []
        var shotStarts: [Double] = []
        var vectors: [Float] = []

        for try await frame in FrameSampler.frames(url: url, duration: duration, options: options) {
            try Task.checkCancellation()
            try await SearchIndexCoordinator.waitWhileExportActive()
            if frame.isNewShot {
                shotStarts.append(shotStarts.isEmpty ? 0 : frame.time)
            }
            vectors += try model.encode(image: frame.image)
            times.append(frame.time)
            shotIndices.append(shotStarts.count - 1)
            if duration > 0 { progress?(min(frame.time / duration, 1)) }
        }
        try Task.checkCancellation()
        let rows = zip(times, shotIndices).map { time, shot in
            EmbeddingStore.Row(
                time: time,
                shotStart: shotStarts[shot],
                shotEnd: shot + 1 < shotStarts.count ? shotStarts[shot + 1] : duration
            )
        }
        try save(rows: rows, vectors: vectors, spec: spec, key: key)
    }

    /// Stills skip the sampler: one embedding, zero-length shot range.
    static func indexImage(url: URL, model: VisualEmbedder) async throws {
        guard let key = EmbeddingStore.key(for: url) else { return }
        guard needsIndex(url: url, spec: model.spec) else { return }
        try await SearchIndexCoordinator.waitWhileExportActive()

        var rows: [EmbeddingStore.Row] = []
        var vectors: [Float] = []
        if let image = decodeImage(url) {
            vectors = try model.encode(image: image)
            rows = [EmbeddingStore.Row(time: 0, shotStart: 0, shotEnd: 0)]
        }
        try Task.checkCancellation()
        try save(rows: rows, vectors: vectors, spec: model.spec, key: key)
    }

    private static func decodeImage(_ url: URL) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func save(rows: [EmbeddingStore.Row], vectors: [Float], spec: VisualEmbedder.Spec, key: String) throws {
        let header = EmbeddingStore.Header(
            model: spec.model, modelVersion: spec.version,
            samplerVersion: FrameSampler.samplerVersion,
            dim: spec.embeddingDim, count: rows.count
        )
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: key)
    }
}
