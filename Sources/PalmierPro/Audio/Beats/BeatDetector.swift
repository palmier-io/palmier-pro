import AVFoundation
import CoreML
import Foundation

private final class BeatDetectorBundleToken {}

struct BeatAnalysis: Codable, Sendable, Equatable {
    let bpm: Double            // 0 when indeterminate
    let beats: [Double]        // seconds in source media
    let downbeats: [Double]
}

/// Detects beats and downbeats on-device using the bundled Beat This Core ML model.
final class BeatDetector: @unchecked Sendable {
    enum DetectError: Error {
        case modelMissing
        case noAudioTrack(String)
        case readFailed(String)
        case badOutput
    }

    // Model contract: 22050 Hz mono, hop 441 (50 logit frames/s), fixed 1500-frame chunks.
    private static let sampleRate = 22050.0
    private static let hop = 441
    private static let chunkFrames = 1500
    private static let chunkSamples = (chunkFrames - 1) * hop
    // Frames discarded per chunk edge, matching Beat This border_size.
    private static let border = 6
    private static let strideFrames = chunkFrames - 2 * border

    private let box: ModelBox

    // MARK: - Cached analysis (UI + agent entry point)

    static let cache = DiskCache(named: "BeatAnalysis")
    private static let shared = try? BeatDetector()
    private static let pipelineGate = AsyncSemaphore(value: 2)

    @concurrent
    static func analysis(for sourceURL: URL, mediaRef: String, force: Bool = false) async throws -> BeatAnalysis {
        if !force, let cached = cachedAnalysis(for: sourceURL, mediaRef: mediaRef) { return cached }
        guard let detector = shared else { throw DetectError.modelMissing }
        try await pipelineGate.wait()
        defer { Task { await pipelineGate.signal() } }
        let analysis = try await detector.detect(in: sourceURL)
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: outputURL)
        }
        return analysis
    }

    static func cachedAnalysis(for sourceURL: URL, mediaRef: String) -> BeatAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: sourceURL, mediaRef: mediaRef)) else { return nil }
        return try? JSONDecoder().decode(BeatAnalysis.self, from: data)
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_beats.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    init(computeUnits: MLComputeUnits = .all) throws {
        guard let url = Self.modelURL() else {
            throw DetectError.modelMissing
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        box = ModelBox(model: try MLModel(contentsOf: url, configuration: config))
    }

    private static func modelURL() -> URL? {
        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Models/BeatThis.mlmodelc"),
            Bundle.main.resourceURL?.appendingPathComponent("PalmierPro_PalmierPro.bundle/Models/BeatThis.mlmodelc"),
        ].compactMap { $0 }
        if Bundle.main.bundleURL.pathExtension != "app" {
            let buildDir = Bundle(for: BeatDetectorBundleToken.self).bundleURL.deletingLastPathComponent()
            candidates.append(buildDir.appendingPathComponent("PalmierPro_PalmierPro.bundle/Models/BeatThis.mlmodelc"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// MLModel.prediction isn't safe to call concurrently; the actor serializes model use.
    private actor ModelBox {
        private let model: MLModel
        init(model: MLModel) { self.model = model }

        func predictLogits(samples: [Float]) throws -> (beat: [Float], downbeat: [Float]) {
            try BeatDetector.predictLogits(samples: samples, model: model)
        }
    }

    func detect(in mediaURL: URL) async throws -> BeatAnalysis {
        let samples = try await Self.decodeAudio(from: mediaURL)
        guard !samples.isEmpty else { return BeatAnalysis(bpm: 0, beats: [], downbeats: []) }
        let (beatLogits, downbeatLogits) = try await box.predictLogits(samples: samples)
        let beats = Self.pickPeaks(beatLogits)
        return BeatAnalysis(
            bpm: Self.estimateBPM(beats) ?? 0,
            beats: beats,
            downbeats: Self.pickPeaks(downbeatLogits)
        )
    }

    // MARK: - Decode

    /// Mono Float32 PCM at 22050 Hz via AVAssetReader (same pattern as Transcription).
    private static func decodeAudio(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DetectError.noAudioTrack(url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw DetectError.readFailed(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readFailed(reader.error?.localizedDescription ?? url.lastPathComponent)
        }

        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length,
                    destination: raw.baseAddress!.advanced(by: start * MemoryLayout<Float>.size)
                )
            }
        }
        if reader.status == .failed {
            throw DetectError.readFailed(reader.error?.localizedDescription ?? "read failed")
        }
        return samples
    }

    // MARK: - Inference

    /// Processes audio in overlapping chunks, keeping only the middle (non-border) frames. Returns logits per 20ms frame.
    private static func predictLogits(samples: [Float], model: MLModel) throws -> (beat: [Float], downbeat: [Float]) {
        let totalFrames = max(1, samples.count / Self.hop + 1)
        var beat = [Float](repeating: -.infinity, count: totalFrames)
        var downbeat = [Float](repeating: -.infinity, count: totalFrames)

        // Start `border` frames early so frame 0 is interior (zeros act as pad).
        var chunkStart = -Self.border  // in frames, relative to the piece
        while chunkStart + Self.border < totalFrames {
            let sampleStart = chunkStart * Self.hop
            var chunk = [Float](repeating: 0, count: Self.chunkSamples)
            let srcLo = max(0, sampleStart)
            let srcHi = min(samples.count, sampleStart + Self.chunkSamples)
            if srcLo < srcHi {
                let dstLo = srcLo - sampleStart
                chunk.replaceSubrange(dstLo..<(dstLo + srcHi - srcLo), with: samples[srcLo..<srcHi])
            }
            let (b, d) = try predictChunk(chunk, model: model)
            for i in Self.border..<(Self.chunkFrames - Self.border) {
                let global = chunkStart + i
                guard global >= 0, global < totalFrames else { continue }
                if beat[global] == -.infinity {  // keep_first
                    beat[global] = b[i]
                    downbeat[global] = d[i]
                }
            }
            chunkStart += Self.strideFrames
        }
        return (beat, downbeat)
    }

    private static func predictChunk(_ chunk: [Float], model: MLModel) throws -> (beat: [Float], downbeat: [Float]) {
        let array = try MLMultiArray(shape: [NSNumber(value: Self.chunkSamples)], dataType: .float32)
        chunk.withUnsafeBufferPointer { src in
            array.withUnsafeMutableBytes { dst, _ in
                dst.copyMemory(from: UnsafeRawBufferPointer(src))
            }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: array)])
        let output = try model.prediction(from: input)
        guard let b = output.featureValue(for: "beat")?.multiArrayValue,
              let d = output.featureValue(for: "downbeat")?.multiArrayValue,
              b.count == Self.chunkFrames, d.count == Self.chunkFrames else {
            throw DetectError.badOutput
        }
        return (Self.floats(b), Self.floats(d))
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        switch array.dataType {
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.map(Float.init) }
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        default:
            return (0..<array.count).map { array[$0].floatValue }
        }
    }

    // MARK: - Postprocess

    /// Picks times (in seconds) where sigmoid(logit) is a local max above 0.5.
    private static func pickPeaks(_ logits: [Float], threshold: Float = 0.5) -> [Double] {
        guard logits.count > 2 else { return [] }
        var times: [Double] = []
        for i in 1..<(logits.count - 1) {
            let p = 1 / (1 + exp(-logits[i]))
            guard p >= threshold, logits[i] >= logits[i - 1], logits[i] > logits[i + 1] else { continue }
            times.append(Double(i * hop) / sampleRate)
        }
        return times
    }

    /// 60 / median inter-beat interval.
    static func estimateBPM(_ beats: [Double]) -> Double? {
        guard beats.count > 2 else { return nil }
        let intervals = zip(beats.dropFirst(), beats).map(-).sorted()
        let median = intervals[intervals.count / 2]
        return median > 0 ? 60.0 / median : nil
    }
}
