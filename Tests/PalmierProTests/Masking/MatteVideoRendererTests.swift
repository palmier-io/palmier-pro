import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Matte video rendering")
struct MatteVideoRendererTests {
    @Test func rendersPlayableMatteWithExpectedGeometry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("matte-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("matte.mov")

        // 64x32, 3 frames: full-row run, empty frame, single pixel.
        let payload = try JSONDecoder().decode(
            MaskTrackPayload.self,
            from: Data(#"{"rle": ["0 64", "", "100 1"]}"#.utf8)
        )
        try await MatteVideoRenderer.render(
            payload: payload,
            width: 64,
            height: 32,
            fps: 30,
            to: url
        )

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 64)
        #expect(Int(size.height) == 32)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 0.1) < 0.01)
    }

    @Test func failsOnMalformedFrameAndCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("matte-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("matte.mov")

        let payload = try JSONDecoder().decode(
            MaskTrackPayload.self,
            from: Data(#"{"rle": ["0 99999999"]}"#.utf8)
        )
        await #expect(throws: (any Error).self) {
            try await MatteVideoRenderer.render(
                payload: payload,
                width: 64,
                height: 32,
                fps: 30,
                to: url
            )
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
