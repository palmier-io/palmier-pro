import Accelerate
import Foundation

struct BeatAnalysis: Codable, Sendable, Equatable {
    let bpm: Double
    let beats: [Double]
}

enum BeatDetector {
    static let cache = DiskCache(named: "BeatAnalysis")

    static let minBPM: Double = 60
    static let maxBPM: Double = 200
    private static let driftTolerance = 0.2
    private static let onsetFloor: Float = 0.25

    private static let pipelineGate = AsyncSemaphore(value: 2)

    // @concurrent keeps decode + detection off the caller's actor even if the
    // default nonisolated-async execution semantics change.
    @concurrent
    static func analysis(for sourceURL: URL, mediaRef: String, force: Bool = false) async throws -> BeatAnalysis {
        if !force, let cached = cachedAnalysis(for: sourceURL, mediaRef: mediaRef) { return cached }
        try await pipelineGate.wait()
        defer { Task { await pipelineGate.signal() } }
        let envelope = try await AudioEnvelopeExtractor.extract(from: sourceURL)
        let analysis = detect(envelope: envelope)
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

    static func detect(envelope: AudioEnvelope) -> BeatAnalysis {
        let hop = envelope.hopSeconds
        let env = envelope.samples
        let minLag = max(1, Int((60.0 / maxBPM / hop).rounded()))
        let maxLag = Int((60.0 / minBPM / hop).rounded())
        guard hop > 0, env.count >= maxLag * 4 else { return BeatAnalysis(bpm: 0, beats: []) }

        var onset = [Float](repeating: 0, count: env.count)
        for i in 1..<env.count { onset[i] = max(0, env[i] - env[i - 1]) }
        var mean: Float = 0
        vDSP_meanv(onset, 1, &mean, vDSP_Length(onset.count))
        guard mean > .ulpOfOne else { return BeatAnalysis(bpm: 0, beats: []) }

        var bestLag = 0
        var bestScore: Float = 0
        onset.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(onset.count - lag))
                let score = dot / Float(onset.count - lag)
                if score > bestScore {
                    bestScore = score
                    bestLag = lag
                }
            }
        }
        guard bestLag > 0, bestScore > 0 else { return BeatAnalysis(bpm: 0, beats: []) }
        let bpm = 60.0 / (Double(bestLag) * hop)

        var bestOffset = 0
        var bestSum: Float = -1
        for offset in 0..<bestLag {
            var sum: Float = 0
            var i = offset
            while i < onset.count {
                sum += onset[i]
                i += bestLag
            }
            if sum > bestSum {
                bestSum = sum
                bestOffset = offset
            }
        }

        let tolerance = max(1, Int(Double(bestLag) * driftTolerance))
        let floor = mean * onsetFloor
        var beats: [Double] = []
        var expected = bestOffset
        while expected < onset.count {
            let lo = max(0, expected - tolerance)
            let hi = min(onset.count - 1, expected + tolerance)
            var peak = expected
            for i in lo...hi where onset[i] > onset[peak] { peak = i }
            if onset[peak] >= floor {
                beats.append(Double(peak) * hop)
                expected = peak + bestLag
            } else {
                expected += bestLag
            }
        }
        return BeatAnalysis(bpm: bpm, beats: beats)
    }
}
