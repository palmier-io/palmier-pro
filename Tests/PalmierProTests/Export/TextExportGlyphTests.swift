import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

/// Regression: text GLYPHS (not just layer background fills) must render in exports.
/// Text now composites through CustomVideoCompositor (TextFrameRenderer), so this also
/// guards the Path B export path end to end.
@Suite("Export — text glyph rendering")
@MainActor
struct TextExportGlyphTests {

    @Test func styledTextClipAtFrameZeroRendersGlyphsFromFirstFrame() async throws {
        let brightness = try await exportBrightness(
            canvas: CGSize(width: 1920, height: 1080), fps: 24, resolution: .r1080p,
            fontScale: 4.13, transform: Transform(centerX: 0.5, centerY: 0.88, width: 0.419, height: 0.232)
        )
        #expect(brightness[0] > 0.001, "glyphs missing on first exported frame: \(brightness.prefix(5))")
        #expect(brightness[20] > 0.001, "glyphs missing mid-clip: \(brightness[20])")
    }

    @Test func plainSmallTextRendersGlyphs() async throws {
        let brightness = try await exportBrightness(
            canvas: CGSize(width: 320, height: 180), fps: 30, resolution: .r720p,
            fontScale: 1.0, transform: Transform()
        )
        // Tiny text: glyphless exports measure ~1e-5; rendered glyphs ~1e-3.
        #expect(brightness[0] > 0.0003, "glyphs missing on first exported frame: \(brightness.prefix(5))")
    }

    private func exportBrightness(
        canvas: CGSize, fps: Int, resolution: ExportResolution,
        fontScale: Double, transform: Transform
    ) async throws -> [Double] {
        let blackURL = try await ImageVideoGenerator.blackVideo(size: CGSize(width: 640, height: 360))
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 5.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let video = Fixtures.clip(id: "v1", mediaRef: mediaRef, start: 0, duration: 115)
        var text = Fixtures.clip(id: "t1", mediaRef: "", mediaType: .text, start: 0, duration: 99)
        text.textContent = "Testing."
        text.fadeOutFrames = 50
        text.transform = transform
        var style = TextStyle()
        style.fontSize = 50
        style.fontScale = fontScale
        style.color = TextStyle.RGBA(r: 1, g: 0.611, b: 0.161, a: 1)
        text.textStyle = style

        var timeline = Fixtures.timeline(fps: fps, tracks: [
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [video]),
        ])
        timeline.width = Int(canvas.width)
        timeline.height = Int(canvas.height)

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: resolution,
            outputURL: outURL
        )
        #expect(svc.error == nil, "export reported error: \(svc.error ?? "")")

        let brightness = try await Self.frameBrightness(url: outURL, frameCount: 21)
        try #require(brightness.count == 21)
        return brightness
    }

    static func frameBrightness(url: URL, frameCount: Int) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()

        var result: [Double] = []
        while result.count < frameCount, let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            var total = 0.0, n = 0.0
            for y in stride(from: 0, to: h, by: 3) {
                for x in stride(from: 0, to: w, by: 3) {
                    let p = base + y * bpr + x * 4
                    total += (Double(p[0]) + Double(p[1]) + Double(p[2])) / (3 * 255)
                    n += 1
                }
            }
            result.append(total / max(n, 1))
        }
        reader.cancelReading()
        return result
    }
}
