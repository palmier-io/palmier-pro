import AVFoundation
import AppKit
import Testing
@testable import PalmierPro

/// End-to-end: a Lottie clip bakes through CompositionBuilder and exports as a real video
/// with its content composited (red probe lands top-left, transparent area over black).
@Suite("Lottie export integration")
@MainActor
struct LottieExportTests {

    @Test func lottieClipExportsWithContent() async throws {
        let renderSize = CGSize(width: 320, height: 180)
        let lottieURL = try LottieVideoGeneratorTests.writeSample()
        defer { try? FileManager.default.removeItem(at: lottieURL) }

        let mediaRef = "lottie-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "probe", type: .lottie,
            source: .external(absolutePath: lottieURL.path), duration: 1.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, mediaType: .lottie, start: 0, duration: 30)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lottie-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: .r720p,
            outputURL: outURL
        )
        #expect(svc.error == nil, "export reported error: \(svc.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        let asset = AVURLAsset(url: outURL)
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let frame = try await gen.image(at: CMTime(value: 0, timescale: 600)).image
        let rep = NSBitmapImageRep(cgImage: frame)
        let topLeft = try #require(rep.colorAt(x: frame.width / 4, y: frame.height / 4))
        let bottomRight = try #require(rep.colorAt(x: frame.width * 3 / 4, y: frame.height * 3 / 4))
        #expect(topLeft.redComponent > 0.5)
        #expect(topLeft.redComponent > topLeft.blueComponent)
        #expect(bottomRight.redComponent < 0.3)
    }
}
