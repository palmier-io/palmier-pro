import AVFoundation
import Foundation
import Testing

enum StoryboardTimingFixtures {
    @concurrent
    static func video(in directory: URL) async throws -> (url: URL, duration: Double) {
        let url = directory.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        do {
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
                throw CocoaError(.fileWriteUnknown)
            }
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0, CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            for second in 0..<5 {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(second), timescale: 1)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
            writer.endSession(atSourceTime: CMTime(value: 5, timescale: 1))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            let duration = try await AVURLAsset(url: url).load(.duration)
            #expect(duration == CMTime(value: 5, timescale: 1))
            return (url, duration.seconds)
        } catch {
            writer.cancelWriting()
            throw error
        }
    }
}
