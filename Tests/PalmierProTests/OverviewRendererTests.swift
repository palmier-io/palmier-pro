import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("OverviewRenderer")
struct OverviewRendererTests {
    @Test func dedupesToDistinctMoments() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheet-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.writeCutVideo(to: url)

        let sheet = try await OverviewRenderer.make(url: url, start: 0, end: 6.0)

        // black → white → black should survive dedup as exactly three tiles
        #expect(sheet.timestamps.count == 3)
        #expect(sheet.timestamps == sheet.timestamps.sorted())
        guard sheet.timestamps.count == 3 else { return }
        #expect(sheet.timestamps[0] < 1.5)
        #expect(sheet.timestamps[1] > 1.5 && sheet.timestamps[1] < 3.5)
        #expect(sheet.timestamps[2] > 3.5 && sheet.timestamps[2] < 5.5)
        #expect(!sheet.jpeg.isEmpty)
    }

    @Test func windowedSheetStaysInWindow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheet-window-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.writeCutVideo(to: url)

        let sheet = try await OverviewRenderer.make(url: url, start: 2.0, end: 6.0)
        #expect(sheet.timestamps.allSatisfy { $0 >= 1.0 && $0 <= 6.0 })
        #expect(sheet.timestamps.count == 2)
    }

    /// 6s of 320×180 H.264 at 12fps: black → white → black, cuts at 2s and 4s
    private static func writeCutVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<72 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let white = (frame / 24) == 1
            guard let pb = adaptor.pixelBufferPool.flatMap({ pool -> CVPixelBuffer? in
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                return out
            }) else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, white ? 255 : 0, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
