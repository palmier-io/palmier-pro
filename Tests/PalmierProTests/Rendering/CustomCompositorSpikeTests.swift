import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// Fills every frame solid blue, ignoring source frames — if the exported file contains
/// blue, the custom compositor ran; if it also contains the text layer's red box, the
/// animation tool post-processed on top of custom compositor output.
final class SpikeSolidBlueCompositor: NSObject, AVVideoCompositing {
    nonisolated(unsafe) static let ciContext = CIContext()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let buffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "spike", code: 1))
            return
        }
        let size = request.renderContext.size
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(origin: .zero, size: size))
        Self.ciContext.render(blue, to: buffer)
        request.finish(withComposedVideoFrame: buffer)
    }
}

/// Architecture gate for the effects engine: AVVideoCompositionCoreAnimationTool must
/// still composite text layers on top of a custom AVVideoCompositing's output at export.
@Suite("Custom compositor — animationTool spike")
@MainActor
struct CustomCompositorSpikeTests {

    @Test func animationToolCompositesTextOverCustomCompositorOutput() async throws {
        let renderSize = CGSize(width: 320, height: 180)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)

        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: "black-fixture", name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 5.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let videoClip = Fixtures.clip(id: "v1", mediaRef: "black-fixture", start: 0, duration: 30)

        // Red background box (glyph-independent coverage) centered at half frame:
        // center stays red, corners stay compositor-blue.
        var textClip = Fixtures.clip(id: "t1", mediaRef: "text", mediaType: .text, start: 0, duration: 30)
        textClip.textContent = "SPIKE"
        var style = TextStyle()
        style.shadow.enabled = false
        style.background = TextStyle.Fill(enabled: true, color: TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1))
        textClip.textStyle = style
        textClip.transform = Transform(width: 0.5, height: 0.5)

        var timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [videoClip, textClip]),
        ])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize
        )

        let mutableVC = result.videoComposition.mutableCopy() as! AVMutableVideoComposition
        mutableVC.customVideoCompositorClass = SpikeSolidBlueCompositor.self
        let (parent, videoLayer) = TextLayerController.buildForExport(
            timeline: timeline, fps: timeline.fps, renderSize: renderSize
        )
        mutableVC.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent
        )

        let session = try #require(AVAssetExportSession(
            asset: result.composition, presetName: AVAssetExportPreset1280x720
        ))
        session.videoComposition = mutableVC

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spike-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try await session.export(to: outURL, as: .mp4)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 15, timescale: 30)).image

        let counts = Self.countPixels(in: frame)
        #expect(counts.blue > 100, "custom compositor output missing — blue pixels: \(counts.blue)")
        #expect(counts.red > 100, "animationTool text missing over custom compositor — red pixels: \(counts.red)")
    }

    private static func countPixels(in image: CGImage) -> (red: Int, blue: Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var red = 0, blue = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = data[i], b = data[i + 2]
            if r > 140 && b < 115 { red += 1 }
            if b > 140 && r < 115 { blue += 1 }
        }
        return (red, blue)
    }
}
