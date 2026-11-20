import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite(.serialized)
struct LoudnessAnalyzerTests {
    private func sine(frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            Float(amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func writeWAV(_ samples: [Float], sampleRate: Double = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudness-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        return url
    }

    private func measure(_ samples: [Float]) async throws -> LoudnessMeasurement {
        let url = try writeWAV(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudness-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        return try await LoudnessAnalyzer.integratedLoudness(
            for: url, mediaRef: UUID().uuidString, cacheDirectory: cache
        )
    }

    @Test func measuresKnownSineNearExpectedLUFS() async throws {
        let measurement = try await measure(sine(frequency: 1_000, amplitude: 0.1, seconds: 5))
        let lufs = try #require(measurement.integratedLUFS)
        #expect(measurement.status == .measured)
        #expect(lufs > -25 && lufs < -20)
    }

    @Test func loudnessScalesWithAmplitude() async throws {
        let quiet = try #require(try await measure(sine(frequency: 1_000, amplitude: 0.1, seconds: 5)).integratedLUFS)
        let loud = try #require(try await measure(sine(frequency: 1_000, amplitude: 0.2, seconds: 5)).integratedLUFS)
        #expect(abs((loud - quiet) - 6.02) < 0.1)
    }

    @Test func varyingLevelsMatchEnergyDomainReference() async throws {
        let levels = Array(repeating: [0.2, 0.02, 0.01, 0.15, 0.005, 0.04, 0.01, 0.3], count: 10).flatMap { $0 }
        let samples = levels.flatMap { sine(frequency: 1_000, amplitude: $0, seconds: 0.5) }
        let lufs = try #require(try await measure(samples).integratedLUFS)
        #expect(lufs.isFinite)
        #expect(lufs < -10 && lufs > -30)
    }

    @Test func signalBelowAbsoluteGateIsExplicit() async throws {
        let measurement = try await measure(sine(frequency: 1_000, amplitude: 0.0001, seconds: 5))
        #expect(measurement.status == .belowGate)
        #expect(measurement.integratedLUFS == nil)
    }

    @Test func shortSignalIsExplicitlyInsufficient() async throws {
        let measurement = try await measure(sine(frequency: 1_000, amplitude: 0.1, seconds: 0.2))
        #expect(measurement.status == .insufficientDuration)
        #expect(measurement.integratedLUFS == nil)
    }

    @Test func analysisRoundTripsThroughCache() async throws {
        let url = try writeWAV(sine(frequency: 440, amplitude: 0.2, seconds: 5))
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudness-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let mediaRef = UUID().uuidString
        let first = try await LoudnessAnalyzer.integratedLoudness(
            for: url, mediaRef: mediaRef, cacheDirectory: cache
        )
        let second = try await LoudnessAnalyzer.integratedLoudness(
            for: url, mediaRef: mediaRef, cacheDirectory: cache
        )
        #expect(second == first)
        #expect((try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).count) == 1)
    }

    @Test func truePeakIsReported() async throws {
        let measurement = try await measure(sine(frequency: 1_000, amplitude: 0.5, seconds: 5))
        #expect(measurement.status == .measured)
        #expect(measurement.truePeakDBFS != nil)
        let tp = try #require(measurement.truePeakDBFS)
        #expect(tp <= -3 && tp >= -10)
    }

    @Test func cacheIdentityIncludesStartTimescale() async throws {
        let samples = sine(frequency: 1_000, amplitude: 0.3, seconds: 1)
            + sine(frequency: 1_000, amplitude: 0.1, seconds: 1)
        let url = try writeWAV(samples)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("loudness-cache-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: cache)
        }
        let duration = CMTime(value: 12, timescale: 30)
        let quiet = try await LoudnessAnalyzer.integratedLoudness(
            for: url, mediaRef: "source", range: CMTimeRange(start: CMTime(value: 30, timescale: 30), duration: duration),
            cacheDirectory: cache)
        let loud = try await LoudnessAnalyzer.integratedLoudness(
            for: url, mediaRef: "source", range: CMTimeRange(start: CMTime(value: 30, timescale: 60), duration: duration),
            cacheDirectory: cache)
        #expect(try #require(loud.integratedLUFS) - #require(quiet.integratedLUFS) > 9)
    }
}
