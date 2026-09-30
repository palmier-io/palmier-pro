import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite(.serialized)
struct DeEsserTests {
    private struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 11) / Float(1 << 53) * 2 - 1
        }
    }

    private func lowpass(_ samples: [Float], cutoffHz: Double, sampleRate: Double) -> [Float] {
        let alpha = 1 - exp(-2 * .pi * cutoffHz / sampleRate)
        var out = [Float](repeating: 0, count: samples.count)
        var y: Double = 0
        for i in samples.indices {
            y += alpha * (Double(samples[i]) - y)
            out[i] = Float(y)
        }
        return out
    }

    private func highpass(_ samples: [Float], cutoffHz: Double, sampleRate: Double) -> [Float] {
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

    /// 4 s @16 kHz: vowel-like segments (harmonics, little HF energy) alternating with
    /// sibilance-like segments (5–7 kHz noise bursts).
    private func writeVowelSibilanceSignal() -> [Float] {
        let sr = 16_000.0
        let n = Int(4 * sr)
        var rng = LCG(state: 99)
        var white = [Float](repeating: 0, count: n)
        for i in 0..<n { white[i] = rng.next() }
        let sibilance = lowpass(highpass(white, cutoffHz: 5_000, sampleRate: sr), cutoffHz: 7_000, sampleRate: sr)

        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let vowelLike = (t < 1.0) || (t >= 1.4 && t < 2.4) || t >= 2.8
            if vowelLike {
                x[i] = 0.5 * Float(sin(2 * .pi * 150 * t))
                    + 0.3 * Float(sin(2 * .pi * 300 * t))
                    + 0.2 * Float(sin(2 * .pi * 600 * t))
            } else {
                x[i] = 0.6 * sibilance[i]
            }
        }
        return x
    }

    @Test func detectsSibilanceNotVowels() {
        let regions = DeEsser.detectRegions(in: writeVowelSibilanceSignal())
        #expect(!regions.isEmpty)
        #expect(regions.contains { $0.start < 1.45 && $0.end > 0.95 })
        #expect(regions.contains { $0.start < 2.85 && $0.end > 2.35 })
        #expect(!regions.contains { $0.start < 0.5 && $0.end > 0.1 })
    }

    @Test func emptySignalYieldsNoRegions() {
        #expect(DeEsser.detectRegions(in: []).isEmpty)
    }

    @Test func analysisRoundTripsThroughCache() async throws {
        let sr = 16_000.0
        let x = writeVowelSibilanceSignal()
        let url = try writeWAV(x, sampleRate: sr)
        defer { try? FileManager.default.removeItem(at: url) }
        let mediaRef = UUID().uuidString
        let first = try await DeEsser.analysis(for: url, mediaRef: mediaRef)
        let cached = DeEsser.cachedAnalysis(for: url, mediaRef: mediaRef)
        #expect(cached == first)
    }

    private func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deess-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return url
    }
}
