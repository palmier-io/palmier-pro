import AVFoundation
import AppKit
import Testing
@testable import PalmierPro

@Suite("LottieVideoGenerator")
struct LottieVideoGeneratorTests {

    /// A 100×100 comp, 30fps, 30 frames, with a solid red 50×50 layer filling the
    /// TOP-LEFT quadrant (comp x:[0,50], y:[0,50] in Lottie's y-down space). Everything
    /// else is transparent — a clean probe for orientation (flip), scale, and alpha.
    static let redCornerLottie = """
    {"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[
    {"ddd":0,"ind":1,"ty":1,"nm":"red","sr":1,"sw":50,"sh":50,"sc":"#ff0000",
     "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[25,25,0]},"a":{"a":0,"k":[25,25,0]},"s":{"a":0,"k":[100,100,100]}},
     "ao":0,"ip":0,"op":30,"st":0,"bm":0}
    ]}
    """

    static func writeSample() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lottie-\(UUID().uuidString).json")
        try redCornerLottie.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test @MainActor func parsesMetadata() async throws {
        let url = try Self.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let meta = try await LottieVideoGenerator.inspect(fileAt: url).meta
        #expect(meta.size == CGSize(width: 100, height: 100))
        #expect(meta.framerate == 30)
        #expect(meta.frameCount == 30)
    }

    /// Renders frame 0 at 2× and checks the red square lands TOP-LEFT (flip correct) and
    /// the opposite corner is transparent (alpha preserved). Also dumps a PNG for eyeballing.
    @Test @MainActor func renderFrameOrientationAndAlpha() async throws {
        let url = try Self.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let view = try await LottieVideoGenerator.loadView(forFileAt: url, target: CGSize(width: 200, height: 200))

        let image = try #require(
            LottieVideoGenerator.renderFrame(view: view, frame: 0, target: CGSize(width: 200, height: 200))
        )
        #expect(image.width == 200 && image.height == 200)

        let rep = NSBitmapImageRep(cgImage: image)
        // Red fills the top-left quadrant [0,100]×[0,100] of the 200×200 render.
        let topLeft = try #require(rep.colorAt(x: 50, y: 50))
        let nearTopLeftEdge = try #require(rep.colorAt(x: 90, y: 90))
        let topRight = try #require(rep.colorAt(x: 150, y: 50))
        let bottomLeft = try #require(rep.colorAt(x: 50, y: 150))
        let bottomRight = try #require(rep.colorAt(x: 150, y: 150))

        #expect(topLeft.alphaComponent > 0.9)
        #expect(topLeft.redComponent > 0.9)
        #expect(topLeft.greenComponent < 0.1)
        #expect(topLeft.blueComponent < 0.1)
        #expect(nearTopLeftEdge.redComponent > 0.9, "red should fill the whole quadrant (scale check)")
        #expect(topRight.alphaComponent < 0.1, "top-right is outside the square")
        #expect(bottomLeft.alphaComponent < 0.1, "bottom-left is outside the square")
        #expect(bottomRight.alphaComponent < 0.1, "bottom-right is outside the square")

        // Visual artifact for manual inspection.
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/lottie-frame0.png"))
        }
    }

    @Test @MainActor func bakesAlphaVideo() async throws {
        let url = try Self.writeSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let ref = "lottie-test-\(UUID().uuidString)"
        let videoURL = try await LottieVideoGenerator.lottieVideo(
            for: url, mediaRef: ref, size: CGSize(width: 200, height: 200)
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let asset = AVURLAsset(url: videoURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 200, height: 200))

        // Held tail makes the clip extendable far past the 1s animation (freeze-frame).
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 60)

        let formats = try await track.load(.formatDescriptions)
        let codec = try #require(formats.first.map { CMFormatDescriptionGetMediaSubType($0) })
        #expect(codec == kCMVideoCodecType_AppleProRes4444)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        nonisolated(unsafe) let unsafeGen = gen

        func sample(_ seconds: Double) async throws -> (top: NSColor, bottom: NSColor) {
            let frame = try await unsafeGen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let rep = NSBitmapImageRep(cgImage: frame)
            return (
                try #require(rep.colorAt(x: frame.width / 4, y: frame.height / 4)),
                try #require(rep.colorAt(x: frame.width * 3 / 4, y: frame.height * 3 / 4))
            )
        }

        // Pixels round-trip with correct orientation: red top-left, transparent/black bottom-right.
        let start = try await sample(0)
        #expect(start.top.redComponent > 0.7)
        #expect(start.bottom.redComponent < 0.3)

        // Past the animation, the frozen last frame is still present (clip is extendable).
        let frozen = try await sample(5)
        #expect(frozen.top.redComponent > 0.7)
    }
}
