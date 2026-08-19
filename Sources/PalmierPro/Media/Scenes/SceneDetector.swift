import AVFoundation
import CoreVideo
import Foundation

struct SceneAnalysis: Codable, Sendable, Equatable {
    let cuts: [Double]
    let duration: Double

    var scenes: [(start: Double, end: Double)] {
        let bounds = [0.0] + cuts.filter { $0 > 0 && $0 < duration } + [duration]
        return zip(bounds, bounds.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            return (start, end)
        }
    }
}

struct SceneAnalysisCacheEntry: Sendable {
    let analysis: SceneAnalysis
    let fileTag: String
}

/// Detects hard cuts from consecutive-frame luma change. No model.
enum SceneDetector {
    enum DetectError: Error {
        case noVideoTrack(String)
        case readFailed(String)
    }

    static let cutThreshold: Float = 12
    static let minimumSceneDuration: Double = 0.4
    private static let sampleWidth = 32
    private static let sampleHeight = 32

    static let cache = DiskCache(named: "SceneAnalysis")
    private static let pipelineGate = AsyncSemaphore(value: 2)
    private static let cacheLookupGate = AsyncSemaphore(value: 2)

    @concurrent
    static func analysis(for sourceURL: URL, mediaRef: String, force: Bool = false) async throws -> SceneAnalysis {
        if !force, let cached = await cachedAnalysis(for: sourceURL, mediaRef: mediaRef) {
            return cached.analysis
        }
        try Task.checkCancellation()
        try await pipelineGate.wait()
        defer { Task { await pipelineGate.signal() } }
        let analysis = try await detect(in: sourceURL)
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: outputURL)
        }
        return analysis
    }

    @concurrent
    static func cachedAnalysis(for sourceURL: URL, mediaRef: String) async -> SceneAnalysisCacheEntry? {
        do {
            try await cacheLookupGate.wait()
        } catch {
            return nil
        }
        defer { Task { await cacheLookupGate.signal() } }
        guard !Task.isCancelled else { return nil }
        let fileTag = DiskCache.sizeMtimeTag(for: sourceURL)
        guard let data = try? Data(contentsOf: analysisURL(mediaRef: mediaRef, fileTag: fileTag)),
              let analysis = try? JSONDecoder().decode(SceneAnalysis.self, from: data) else { return nil }
        guard !Task.isCancelled else { return nil }
        return SceneAnalysisCacheEntry(analysis: analysis, fileTag: fileTag)
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        analysisURL(mediaRef: mediaRef, fileTag: DiskCache.sizeMtimeTag(for: sourceURL))
    }

    private static func analysisURL(mediaRef: String, fileTag: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(fileTag)_scenes.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    @concurrent
    static func detect(in mediaURL: URL) async throws -> SceneAnalysis {
        let asset = AVURLAsset(url: mediaURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DetectError.noVideoTrack(mediaURL.lastPathComponent)
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let output = Self.trackOutput(track: track)
        guard reader.canAdd(output) else { throw DetectError.readFailed("cannot add video output") }
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readFailed(reader.error?.localizedDescription ?? "read failed")
        }

        var cuts: [Double] = []
        var lastGrid: [Float]?
        var lastCutTime = -Double.infinity
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += 1
            if frames.isMultiple(of: 15) { try Task.checkCancellation() }
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let grid = LumaGrid.compute(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let lastGrid, LumaGrid.meanDiff(grid, lastGrid) > cutThreshold,
               time - lastCutTime >= minimumSceneDuration, time > 0 {
                cuts.append(time)
                lastCutTime = time
            }
            lastGrid = grid
        }
        if reader.status == .failed {
            throw DetectError.readFailed(reader.error?.localizedDescription ?? "read failed")
        }
        try Task.checkCancellation()
        let finiteDuration = duration.isFinite && duration > 0 ? duration : (cuts.last ?? 0)
        return SceneAnalysis(
            cuts: cuts.filter { $0 < finiteDuration },
            duration: finiteDuration
        )
    }

    private static func trackOutput(track: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: sampleWidth,
            kCVPixelBufferHeightKey as String: sampleHeight,
        ])
        output.alwaysCopiesSampleData = false
        return output
    }
}
