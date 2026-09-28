import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite(.serialized)
struct LoudnessAnalyzerTests {
    private func sine(frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in
            Float(amplitude * sin(2 * .pi * frequency * Double(i) / sampleRate))
        }
    }

    private func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudness-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return url
    }

    @Test func measuresKnownSineNearExpectedLUFS() {
        // 1 kHz sine at amplitude 0.1 (-23 dBFS RMS); K-weighting adds roughly +0.7 dB at 1 kHz.
        let lufs = LoudnessAnalyzer.measure(in: sine(frequency: 1_000, amplitude: 0.1, seconds: 2, sampleRate: 48_000))
        #expect(lufs > -25 && lufs < -20)
    }

    @Test func loudnessScalesWithAmplitude() {
        let quiet = LoudnessAnalyzer.measure(in: sine(frequency: 1_000, amplitude: 0.1, seconds: 2, sampleRate: 48_000))
        let loud = LoudnessAnalyzer.measure(in: sine(frequency: 1_000, amplitude: 0.2, seconds: 2, sampleRate: 48_000))
        #expect(abs((loud - quiet) - 6.02) < 0.05)
    }

    @Test func signalBelowAbsoluteGateReturnsGate() {
        let lufs = LoudnessAnalyzer.measure(in: sine(frequency: 1_000, amplitude: 0.0001, seconds: 2, sampleRate: 48_000))
        #expect(lufs == -70.0)
    }

    @Test func nonMultipleOfBlockSizeStillMeasures() {
        let lufs = LoudnessAnalyzer.measure(in: sine(frequency: 1_000, amplitude: 0.1, seconds: 0.5, sampleRate: 48_000))
        #expect(lufs > -25 && lufs < -10)
    }

    @Test func analysisRoundTripsThroughCache() async throws {
        let url = try writeWAV(sine(frequency: 440, amplitude: 0.2, seconds: 1, sampleRate: 48_000), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let mediaRef = UUID().uuidString
        let first = try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: mediaRef)
        let cached = LoudnessAnalyzer.cachedLoudness(for: url, mediaRef: mediaRef)
        #expect(cached == first)
        let second = try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: mediaRef)
        #expect(second == first)
    }
}
