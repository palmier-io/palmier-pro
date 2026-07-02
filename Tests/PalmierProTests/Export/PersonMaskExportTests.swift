import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

/// Closes the "does it actually work on export" loop for the people-mask feature. Unlike
/// `PersonMaskCompositingTests` (which inspects frames straight out of `CustomVideoCompositor`),
/// this runs the real `ExportService.export` -> `AVAssetExportSession` path and re-reads the
/// *encoded output file* to confirm the mask survives the same route a real export takes.
@Suite("key.personMask — export round-trip")
@MainActor
struct PersonMaskExportTests {

    static let size = CompositorFixtures.renderSize  // 320×180

    private func isMagenta(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 140 && p.b > 140 && p.g < 100 }
    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 140 && p.r < 110 && p.b < 110 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g > 170 && p.b > 170 }

    @Test func exportedFileHasMaskedRegionShowingBackground() async throws {
        let matteURL = try await PersonMaskCompositingTests.halfMatteVideoURL()
        let bgURL = try await PersonMaskCompositingTests.solidVideoURL(name: "personmask-export-bg-magenta", r: 1, g: 0, b: 1)
        let patternURL = try await CompositorFixtures.patternVideoURL()

        var fg = CompositorFixtures.patternClip(id: "fg")
        fg.effects = [Effect(type: "key.personMask", params: [
            "maskCachePath": EffectParam(string: matteURL.path),
            "invert": EffectParam(value: 0),
            "feather": EffectParam(value: 0),
        ])]
        let bg = Fixtures.clip(id: "bg", mediaRef: "mask-bg", start: 0, duration: 60)

        var manifest = MediaManifest()
        manifest.entries = [
            MediaManifestEntry(id: "pattern", name: "pattern", type: .video, source: .external(absolutePath: patternURL.path), duration: 5.0),
            MediaManifestEntry(id: "mask-bg", name: "mask-bg", type: .video, source: .external(absolutePath: bgURL.path), duration: 5.0),
        ]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        var timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [fg]),
            Fixtures.videoTrack(clips: [bg]),
        ])
        timeline.width = Int(Self.size.width)
        timeline.height = Int(Self.size.height)

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("personmask-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(timeline: timeline, resolver: resolver, format: .h264, resolution: .r720p, outputURL: outURL)
        #expect(svc.error == nil, "export reported error: \(svc.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        // Read a frame straight out of the encoded file — no videoComposition here, so
        // whatever pixels are baked in are exactly what the compositor+kernel produced.
        let asset = AVURLAsset(url: outURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let duration = try await asset.load(.duration)
        let midpoint = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
        let cg = try await gen.image(at: midpoint).image
        let frame = CompositorRenderTests.Frame(bytes: ColorProbeHelpers.srgbBytes(cg, size: Self.size), w: Int(Self.size.width))

        #expect(isMagenta(frame.tl), "left half has no coverage — bg should show through in the exported file: \(frame.tl)")
        #expect(isMagenta(frame.bl), "left half has no coverage — bg should show through in the exported file: \(frame.bl)")
        #expect(isGreen(frame.tr), "right half is fully covered — fg keeps its own color: \(frame.tr)")
        #expect(isWhite(frame.br), "right half is fully covered — fg keeps its own color: \(frame.br)")
    }
}
