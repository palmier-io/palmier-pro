import AVFoundation
import Foundation
@testable import CompositorPro

enum AudioFinishingFixtures {
    @concurrent
    static func makeDirectory() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = Float(0.05 * sin(2 * .pi * 1_000 * Double(index) / 48_000))
        }
        try file.write(from: buffer)
        return directory
    }

    @concurrent
    static func remove(_ directory: URL) async throws { try FileManager.default.removeItem(at: directory) }

    @concurrent
    static func writeTone(to url: URL, amplitudes: [Double], secondsPerLevel: Double = 1) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = Int(48_000 * secondsPerLevel)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = buffer.frameCapacity
        for amplitude in amplitudes {
            for index in 0..<count {
                buffer.floatChannelData![0][index] = Float(amplitude * sin(2 * .pi * 1_000 * Double(index) / 48_000))
            }
            try file.write(from: buffer)
        }
    }

    @concurrent
    static func rms(_ url: URL, range: ClosedRange<Double> = 0.2...1.8) async throws -> Double {
        let samples = try await AudioTrackReader.readMonoFloats(from: url, sampleRate: 48_000, range: range)
        guard !samples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
}
