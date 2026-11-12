import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("EditorViewModel — sequential audio imports")
@MainActor
struct SequentialAudioImportTests {
    private func makeWAV(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-import-\(UUID().uuidString)-\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let samples = [Float](repeating: 0.25, count: 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        return url
    }

    @Test func twoSequentialAudioImportsBothFinalize() async throws {
        let editor = EditorViewModel()
        let first = try makeWAV(name: "first")
        let second = try makeWAV(name: "second")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let summaryA = try await editor.importFinderItems([first], into: nil, finalize: true)
        let summaryB = try await editor.importFinderItems([second], into: nil, finalize: true)

        #expect(summaryA.assetCount == 1)
        #expect(summaryB.assetCount == 1)
        #expect(editor.mediaAssets.count { $0.type == .audio && $0.duration > 0 } == 2)
    }
}
