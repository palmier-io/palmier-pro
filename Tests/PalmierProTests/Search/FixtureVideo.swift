import AVFoundation
import CoreVideo
import Foundation

/// Renders a small H.264 video of solid-color scenes for sampler/indexer tests.
enum FixtureVideo {
    struct Scene {
        let rgb: (UInt8, UInt8, UInt8)
        let seconds: Double
    }

    static func write(scenes: [Scene], fps: Int32 = 5, size: Int = 320) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        for scene in scenes {
            let buffer = try solidBuffer(rgb: scene.rgb, size: size, pool: adaptor.pixelBufferPool)
            for _ in 0..<Int(scene.seconds * Double(fps)) {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(10))
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
                frameIndex += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "FixtureVideo", code: 1)
        }
        return url
    }

    private static func solidBuffer(rgb: (UInt8, UInt8, UInt8), size: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw NSError(domain: "FixtureVideo", code: 2) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<size {
            for x in 0..<size {
                let p = base + y * bytesPerRow + x * 4
                p[0] = rgb.2; p[1] = rgb.1; p[2] = rgb.0; p[3] = 255
            }
        }
        return buffer
    }
}
