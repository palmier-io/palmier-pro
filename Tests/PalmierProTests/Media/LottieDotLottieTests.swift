import AVFoundation
import AppKit
import Testing
@testable import PalmierPro

@Suite("Lottie dotLottie")
struct LottieDotLottieTests {

    /// A real `.lottie` (zip of manifest.json + animations/anim.json): a 400×400, 2s bouncing-dot
    /// animation. Base64-embedded so the test is self-contained.
    static let dotLottieBase64 = "UEsDBBQAAAAIAEuwz1wI8a0UUwAAAGEAAAANAAAAbWFuaWZlc3QuanNvbhXKMQ6AIAxG4bv8MxJYuYpxILExJEJJqS6Eu1vX972Jl2QUbkiIPvgAh4saSVYWaz3ftZBsSkONcis1q+0DaZ8opy1/M7qZO5LKQw6jExnFdawPUEsDBAoAAAAAAEuwz1wAAAAAAAAAAAAAAAALAAAAYW5pbWF0aW9ucy9QSwMEFAAAAAgAS7DPXCMVmRqVAQAA9QUAABQAAABhbmltYXRpb25zL2FuaW0uanNvbq1U246CMBR85yuaPrukBctm/RXTBxRUoguGshdj+Pc9pzdAiskmJoTM4VymM6W9R4TQb7ohVMTvMaMrQg8thCkDVF0BIWgQZIh+AKwZopNH9Sf275qvel/Vx7ei6XBMURS2O1eq7BQEW7lCukt+K1sd3yEk49KqRsQBdTec76fboarVadN2xhlmBEQNBjS3g85Yx1gPsJ0l4LPrus6SWwD4SOzNn6fVPM3REveSveaxdDRvdKUJ1Cm/liMXiNVMjy31so/Ur7TqsNZGBGhNdXnRZlvXQgtKcC2JWfCCXNl7R4bJBz150da9T3A3yo/QQ2yLlsjiBGjibIXFXOJO6/ZfkxT45aZXq5fZhJPTdTqSzLNw5EjxJZCl96VBfV1Lx8NG3oQEjSRZtg+ACewxfpioyZ6pWS+qcQyp15NyT/FShsExp6EfVclJz9IReKhS/zRPwA4J3NlH84TevkGf3sjZLzEtmv3CITO5wHMg5ma+mHEw12p84m3walo6c77RIWkuF2kvlMBtrdwh3OFtwiKsjvroD1BLAQIeAxQAAAAIAEuwz1wI8a0UUwAAAGEAAAANAAAAAAAAAAEAAACkgQAAAABtYW5pZmVzdC5qc29uUEsBAh4DCgAAAAAAS7DPXAAAAAAAAAAAAAAAAAsAAAAAAAAAAAAQAO1BfgAAAGFuaW1hdGlvbnMvUEsBAh4DFAAAAAgAS7DPXCMVmRqVAQAA9QUAABQAAAAAAAAAAQAAAKSBpwAAAGFuaW1hdGlvbnMvYW5pbS5qc29uUEsFBgAAAAADAAMAtgAAAG4CAAAAAA=="

    static func writeSample() throws -> URL {
        guard let data = Data(base64Encoded: dotLottieBase64) else { throw CocoaError(.fileReadCorruptFile) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lottie")
        try data.write(to: url)
        return url
    }

    @Test func sniffAcceptsZipArchive() throws {
        let url = try Self.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LottieVideoGenerator.isLottie(at: url))
    }

    @Test @MainActor func inspectsAndBakes() async throws {
        let url = try Self.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try await LottieVideoGenerator.inspect(fileAt: url)
        #expect(info.meta.size == CGSize(width: 400, height: 400))
        #expect(info.meta.framerate == 30)
        #expect(info.meta.frameCount == 60)   // 2s @ 30fps
        #expect(info.thumbnail != nil)

        let mov = try await LottieVideoGenerator.lottieVideo(
            for: url, mediaRef: "dot-\(UUID().uuidString)", size: CGSize(width: 400, height: 400)
        )
        defer { try? FileManager.default.removeItem(at: mov) }

        let asset = AVURLAsset(url: mov)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 400, height: 400))

        // Frame 0: the blue dot sits left-of-center — blue on the left, empty on the right.
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cg)
        let left = try #require(rep.colorAt(x: cg.width / 4, y: cg.height / 2))
        let right = try #require(rep.colorAt(x: cg.width * 3 / 4, y: cg.height / 2))
        #expect(left.blueComponent > 0.6)
        #expect(left.blueComponent > left.redComponent)
        #expect(right.blueComponent < 0.3)
    }

    /// inspect_media's frame sampling: evenly spaced indices, and motion is captured — the dot
    /// is on the left at frame 0 and on the right at the middle frame.
    @Test @MainActor func samplesFramesForInspection() async throws {
        let url = try Self.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }

        let (meta, frames) = try await LottieVideoGenerator.sampleFrames(fileAt: url, count: 5)
        #expect(meta.frameCount == 60)
        #expect(frames.map(\.frameIndex) == [0, 15, 30, 44, 59])

        let first = frames[0].image
        let mid = frames[2].image
        func alpha(_ image: CGImage, x: Int, y: Int) throws -> CGFloat {
            try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)).alphaComponent
        }
        let w = first.width, h = first.height
        // Frame 0: dot left, right empty.
        #expect(try alpha(first, x: w / 4, y: h / 2) > 0.5)
        #expect(try alpha(first, x: w * 3 / 4, y: h / 2) < 0.2)
        // Middle frame: dot right, left empty.
        #expect(try alpha(mid, x: w * 3 / 4, y: h / 2) > 0.5)
        #expect(try alpha(mid, x: w / 4, y: h / 2) < 0.2)
    }
}
