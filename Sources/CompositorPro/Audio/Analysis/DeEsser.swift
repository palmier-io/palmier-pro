import AVFoundation
import Foundation

/// Detects sibilance ("s", "sh", "ch" bursts): frames where the 4–8 kHz band
/// dominates the spectrum. Pure DSP — no model, works without the BundledSpeech trait.
/// Applied as gain dips, mirroring the de-breath pipeline.
enum DeEsser {
    static let cache = DiskCache(named: "AudioAnalysis")

    struct Region: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
    }

    struct Analysis: Codable, Equatable, Sendable {
        let regions: [Region]
    }

    private static let sampleRate = 16_000.0
    private static let frameSize = 512
    private static let hop = 256
    private static let sibilanceLowHz = 4_000.0
    private static let sibilanceHighHz = 8_000.0
    private static let ratioGateDB = -12.0
    private static let minRegionSeconds = 0.03
    private static let maxRegionSeconds = 0.5
    private static let mergeGapSeconds = 0.03
    private static let edgePadSeconds = 0.01

    static func analysis(for sourceURL: URL, mediaRef: String) async throws -> Analysis {
        if let cached = cachedAnalysis(for: sourceURL, mediaRef: mediaRef) { return cached }
        let samples = try await AudioTrackReader.readMonoFloats(from: sourceURL, sampleRate: sampleRate)
        let analysis = Analysis(regions: detectRegions(in: samples))
        cache(analysis, for: sourceURL, mediaRef: mediaRef)
        return analysis
    }

    static func cachedAnalysis(for sourceURL: URL, mediaRef: String) -> Analysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: sourceURL, mediaRef: mediaRef)) else { return nil }
        return try? JSONDecoder().decode(Analysis.self, from: data)
    }

    static func detectRegions(in samples: [Float]) -> [Region] {
        guard samples.count >= frameSize else { return [] }
        let frameCount = (samples.count - frameSize) / hop + 1
        guard frameCount > 0 else { return [] }
        let duration = Double(samples.count) / sampleRate

        let sibilance = lowpass(highpass(samples, cutoffHz: sibilanceLowHz), cutoffHz: sibilanceHighHz)
        var ratioDB = [Double](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            let start = f * hop
            let band = rmsDB(sibilance, start: start)
            let total = rmsDB(samples, start: start)
            ratioDB[f] = band - total
        }
        let threshold = percentile(ratioDB, 0.8) - 2
        let frameDuration = Double(hop) / sampleRate

        var regions: [Region] = []
        var regionStart: Double?
        var lastSibilant: Double?
        for f in 0..<frameCount {
            let isSibilant = ratioDB[f] > threshold && ratioDB[f] > ratioGateDB
            let t = Double(f) * frameDuration
            if isSibilant {
                if regionStart == nil { regionStart = t }
                lastSibilant = t
            } else if let start = regionStart, let last = lastSibilant {
                if t - last > mergeGapSeconds {
                    regions.append(makeRegion(start: start, end: last + frameDuration, duration: duration))
                    regionStart = nil
                    lastSibilant = nil
                }
            }
        }
        if let start = regionStart, let last = lastSibilant {
            regions.append(makeRegion(start: start, end: last + frameDuration, duration: duration))
        }
        return regions
    }

    private static func makeRegion(start: Double, end: Double, duration: Double) -> Region {
        let paddedStart = max(0, start - edgePadSeconds)
        let paddedEnd = min(duration, end + edgePadSeconds)
        guard paddedEnd - paddedStart >= minRegionSeconds,
              paddedEnd - paddedStart <= maxRegionSeconds + 2 * edgePadSeconds
        else { return Region(start: start, end: min(end, start + minRegionSeconds)) }
        return Region(start: paddedStart, end: paddedEnd)
    }

    private static func rmsDB(_ signal: [Float], start: Int) -> Double {
        var sum: Double = 0
        let end = min(start + frameSize, signal.count)
        guard start < end else { return -120 }
        for i in start..<end {
            sum += Double(signal[i]) * Double(signal[i])
        }
        return 20 * log10((sum / Double(end - start)).squareRoot() + 1e-9)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return -120 }
        let sorted = values.sorted()
        let index = Int((fraction * Double(sorted.count - 1)).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private static func lowpass(_ samples: [Float], cutoffHz: Double) -> [Float] {
        let alpha = 1 - exp(-2 * .pi * cutoffHz / sampleRate)
        var out = [Float](repeating: 0, count: samples.count)
        var y: Double = 0
        for i in samples.indices {
            y += alpha * (Double(samples[i]) - y)
            out[i] = Float(y)
        }
        return out
    }

    private static func highpass(_ samples: [Float], cutoffHz: Double) -> [Float] {
        let rc = 1 / (2 * .pi * cutoffHz)
        let alpha = rc / (rc + 1 / sampleRate)
        var out = [Float](repeating: 0, count: samples.count)
        var y: Double = 0
        var prevX: Double = 0
        for i in samples.indices {
            let x = Double(samples[i])
            y = alpha * (y + x - prevX)
            prevX = x
            out[i] = Float(y)
        }
        return out
    }

    private static func cache(_ analysis: Analysis, for sourceURL: URL, mediaRef: String) {
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: outputURL)
        }
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_deess.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }
}
