import AVFoundation
import Testing
@testable import PalmierPro
@Test @concurrent
func catalogResolutionCapsDimensions() async throws {
    let sourceURL = try await FixtureVideo.write(scenes: [.init(rgb: (32, 64, 128), seconds: 0.2)], size: 800)
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let outputURL = try #require(await VideoPreprocessor.transcodeIfNeeded(
        url: sourceURL,
        maxResolution: .p720,
        requiredEncoding: nil
    ))
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let track = try #require(await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(max(size.width, size.height) <= 1280 && min(size.width, size.height) <= 720)
}

@Test @concurrent
func requiredH264MP4ConvertsQuickTimeSource() async throws {
    let sourceURL = try await FixtureVideo.write(
        scenes: [.init(rgb: (32, 64, 128), seconds: 0.2)],
        fileType: .mov
    )
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let outputURL = try #require(await VideoPreprocessor.transcodeIfNeeded(
        url: sourceURL,
        maxResolution: nil,
        requiredEncoding: .h264MP4
    ))
    defer { try? FileManager.default.removeItem(at: outputURL) }

    #expect(outputURL.pathExtension == "mp4")
    let track = try #require(await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video).first)
    let descriptions = try await track.load(.formatDescriptions)
    #expect(!descriptions.isEmpty)
    #expect(descriptions.allSatisfy {
        CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
    })
}

@Test @concurrent
func requiredH264MP4KeepsCompatibleSource() async throws {
    let sourceURL = try await FixtureVideo.write(
        scenes: [.init(rgb: (32, 64, 128), seconds: 0.2)]
    )
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let outputURL = try await VideoPreprocessor.transcodeIfNeeded(
        url: sourceURL,
        maxResolution: nil,
        requiredEncoding: .h264MP4
    )
    #expect(outputURL == nil)
}
