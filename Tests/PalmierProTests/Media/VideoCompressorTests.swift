import AVFoundation
import Testing
@testable import PalmierPro
@Test @concurrent
func catalogResolutionCapsDimensions() async throws {
    let sourceURL = try await FixtureVideo.write(scenes: [.init(rgb: (32, 64, 128), seconds: 0.2)], size: 800)
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let outputURL = try #require(await VideoCompressor.compressIfNeeded(url: sourceURL, maxResolution: .p720))
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let track = try #require(await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(max(size.width, size.height) <= 1280 && min(size.width, size.height) <= 720)
}
