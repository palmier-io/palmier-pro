import AVFoundation
import Foundation

/// BS.1770-4 integrated loudness (K-weighted, gated) for matching clip loudness.
/// Reads at 48 kHz so the standard K-weighting coefficients apply directly.
enum LoudnessAnalyzer {
    static let cache = DiskCache(named: "AudioAnalysis")

    private static let sampleRate = 48_000.0
    private static let blockSeconds = 0.4
    private static let absoluteGateLUFS = -70.0
    private static let relativeGateLU = 10.0

    // K-weighting at 48 kHz per ITU-R BS.1770-4.
    private static let shelf = Biquad(
        b: [1.53512485958697, -2.69169618940638, 1.19839281085285],
        a: [1, -1.69065929318241, 0.73248077421585]
    )
    private static let highpass = Biquad(
        b: [1, -2, 1],
        a: [1, -1.99004745483399, 0.99007225036621]
    )

    static func integratedLoudness(for sourceURL: URL, mediaRef: String) async throws -> Double {
        if let cached = cachedLoudness(for: sourceURL, mediaRef: mediaRef) { return cached }
        let samples = try await AudioTrackReader.readMonoFloats(from: sourceURL, sampleRate: sampleRate)
        let lufs = measure(in: samples)
        cache(lufs, for: sourceURL, mediaRef: mediaRef)
        return lufs
    }

    static func cachedLoudness(for sourceURL: URL, mediaRef: String) -> Double? {
        guard let data = try? Data(contentsOf: analysisURL(for: sourceURL, mediaRef: mediaRef)) else { return nil }
        return try? JSONDecoder().decode(Double.self, from: data)
    }

    /// Integrated loudness in LUFS. Returns the absolute gate when nothing passes it.
    static func measure(in samples: [Float]) -> Double {
        guard !samples.isEmpty else { return absoluteGateLUFS }
        var filtered = shelf.process(samples)
        filtered = highpass.process(filtered)
        let blockSize = Int(blockSeconds * sampleRate)
        var blockLUFS = [Double]()
        var index = 0
        while index + blockSize <= filtered.count {
            var sum: Double = 0
            for i in index..<(index + blockSize) {
                sum += Double(filtered[i]) * Double(filtered[i])
            }
            blockLUFS.append(-0.691 + 10 * log10(sum / Double(blockSize) + 1e-12))
            index += blockSize
        }
        let ungated = blockLUFS.filter { $0 > absoluteGateLUFS }
        guard !ungated.isEmpty else { return absoluteGateLUFS }
        let mean = ungated.reduce(0, +) / Double(ungated.count)
        let gated = ungated.filter { $0 > mean - relativeGateLU }
        return gated.reduce(0, +) / Double(gated.count)
    }

    private static func cache(_ lufs: Double, for sourceURL: URL, mediaRef: String) {
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        if let data = try? JSONEncoder().encode(lufs) {
            try? data.write(to: outputURL)
        }
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_loudness.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }
}

struct Biquad {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    init(b: [Double], a: [Double]) {
        b0 = b[0]; b1 = b[1]; b2 = b[2]
        a1 = a[1]; a2 = a[2]
    }

    func process(_ input: [Float]) -> [Float] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var out = [Float](repeating: 0, count: input.count)
        for i in input.indices {
            let x = Double(input[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            out[i] = Float(y)
        }
        return out
    }
}
