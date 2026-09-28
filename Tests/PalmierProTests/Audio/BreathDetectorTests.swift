import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite(.serialized)
struct BreathDetectorTests {
    /// Deterministic LCG so the synthetic signal is identical on every run.
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

    /// 4 s @16 kHz: speech-like segments (harmonics + HF noise) alternating with
    /// breath-like segments (low-frequency noise only, no consonant energy).
    private func writeSpeechBreathSignal() -> [Float] {
        let sr = 16_000.0
        let n = Int(4 * sr)
        var rng = LCG(state: 42)
        var white = [Float](repeating: 0, count: n)
        for i in 0..<n { white[i] = rng.next() }
        let whiteLow = lowpass(white, cutoffHz: 1_000, sampleRate: sr)
        let hf = zip(white, whiteLow).map { $0 - $1 }
        let breathNoise = lowpass(white, cutoffHz: 300, sampleRate: sr)

        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let speechLike = (t < 1.0) || (t >= 1.4 && t < 2.4) || t >= 2.8
            if speechLike {
                x[i] = 0.5 * Float(sin(2 * .pi * 150 * t))
                    + 0.3 * Float(sin(2 * .pi * 300 * t))
                    + 0.4 * hf[i]
            } else {
                x[i] = 0.35 * breathNoise[i]
            }
        }
        return x
    }

    @Test func detectsBreathSegmentsNotSpeechSegments() {
        let regions = BreathDetector.detectRegions(in: writeSpeechBreathSignal())
        #expect(!regions.isEmpty)
        #expect(regions.contains { $0.start < 1.45 && $0.end > 0.95 })
        #expect(regions.contains { $0.start < 2.85 && $0.end > 2.35 })
        #expect(!regions.contains { $0.start < 0.5 && $0.end > 0.1 })
    }

    private func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("breath-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return url
    }

    @Test func emptyAndShortSignalsYieldNoRegions() {
        #expect(BreathDetector.detectRegions(in: []).isEmpty)
        #expect(BreathDetector.detectRegions(in: [Float](repeating: 0, count: 100)).isEmpty)
    }

    @Test func analysisRoundTripsThroughCache() async throws {
        let sr = 16_000.0
        var rng = LCG(state: 7)
        let n = Int(2 * sr)
        var white = [Float](repeating: 0, count: n)
        for i in 0..<n { white[i] = rng.next() }
        let breathNoise = lowpass(white, cutoffHz: 300, sampleRate: sr)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            x[i] = t < 1.0
                ? 0.5 * Float(sin(2 * .pi * 200 * t)) + 0.3 * white[i]
                : 0.3 * breathNoise[i]
        }
        let url = try writeWAV(x, sampleRate: sr)
        defer { try? FileManager.default.removeItem(at: url) }

        let mediaRef = UUID().uuidString
        let first = try await BreathDetector.analysis(for: url, mediaRef: mediaRef)
        let cached = BreathDetector.cachedAnalysis(for: url, mediaRef: mediaRef)
        #expect(cached == first)
    }
}
