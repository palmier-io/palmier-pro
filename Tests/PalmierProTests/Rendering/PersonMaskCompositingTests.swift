import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

/// End-to-end coverage for the `key.personMask` composition/render plumbing (Phase 2 of the
/// people-mask feature) — exercises the real `CompositionBuilder` -> `AVMutableVideoComposition`
/// -> `CustomVideoCompositor` -> `PersonMaskKernel` pipeline, standing in for a real Vision-baked
/// matte with a synthetic still "matte video" (left half = no coverage, right half = full
/// coverage). This can't cover Vision's own person detection (needs real footage of a person),
/// but it proves the parallel mask track stays frame-locked and pixel-aligned with the main clip.
@Suite("key.personMask — composition & render")
@MainActor
struct PersonMaskCompositingTests {

    static let size = CompositorFixtures.renderSize  // 320×180

    /// Half-black/half-white still video standing in for a baked matte: left = no coverage,
    /// right = full coverage.
    static func halfMatteVideoURL() async throws -> URL {
        let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("personmask-half-matte.png")
        if !FileManager.default.fileExists(atPath: png.path) {
            let w = Int(size.width), h = Int(size.height)
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
            let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        return try await ImageVideoGenerator.stillVideo(for: png, mediaRef: "personmask-half-matte", size: size)
    }

    /// Solid-color still video used as an unambiguous background layer.
    static func solidVideoURL(name: String, r: Double, g: Double, b: Double) async throws -> URL {
        let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        if !FileManager.default.fileExists(atPath: png.path) {
            let w = Int(size.width), h = Int(size.height)
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        return try await ImageVideoGenerator.stillVideo(for: png, mediaRef: name, size: size)
    }

    private func isMagenta(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 140 && p.b > 140 && p.g < 100 }
    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 140 && p.r < 110 && p.b < 110 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g > 170 && p.b > 170 }

    private func personMaskEffect(invert: Double = 0, feather: Double = 0, matteURL: URL) -> Effect {
        Effect(type: "key.personMask", params: [
            "maskCachePath": EffectParam(string: matteURL.path),
            "invert": EffectParam(value: invert),
            "feather": EffectParam(value: feather),
        ])
    }

    @Test func maskedRegionRevealsBackgroundBehindIt() async throws {
        let matteURL = try await Self.halfMatteVideoURL()
        let bgURL = try await Self.solidVideoURL(name: "personmask-bg-magenta", r: 1, g: 0, b: 1)

        var fg = CompositorFixtures.patternClip(id: "fg")
        fg.effects = [personMaskEffect(matteURL: matteURL)]
        let bg = Fixtures.clip(id: "bg", mediaRef: "mask-bg", start: 0, duration: 60)

        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [fg]),
            Fixtures.videoTrack(clips: [bg]),
        ])
        let f = try await CompositorRenderTests.render(
            timeline, frame: 15, imageURLs: ["pattern": try await CompositorFixtures.patternVideoURL(), "mask-bg": bgURL]
        )
        #expect(isMagenta(f.tl), "left half has no coverage — bg should show through: \(f.tl)")
        #expect(isMagenta(f.bl), "left half has no coverage — bg should show through: \(f.bl)")
        #expect(isGreen(f.tr), "right half is fully covered — fg keeps its own color: \(f.tr)")
        #expect(isWhite(f.br), "right half is fully covered — fg keeps its own color: \(f.br)")
    }

    @Test func invertFlipsWhichSideIsCutOut() async throws {
        let matteURL = try await Self.halfMatteVideoURL()
        let bgURL = try await Self.solidVideoURL(name: "personmask-bg-magenta", r: 1, g: 0, b: 1)

        var fg = CompositorFixtures.patternClip(id: "fg")
        fg.effects = [personMaskEffect(invert: 1, matteURL: matteURL)]
        let bg = Fixtures.clip(id: "bg", mediaRef: "mask-bg", start: 0, duration: 60)

        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [fg]),
            Fixtures.videoTrack(clips: [bg]),
        ])
        let f = try await CompositorRenderTests.render(
            timeline, frame: 15, imageURLs: ["pattern": try await CompositorFixtures.patternVideoURL(), "mask-bg": bgURL]
        )
        #expect(!isMagenta(f.tl), "inverted: left half now keeps fg content: \(f.tl)")
        #expect(isMagenta(f.tr), "inverted: right half is now cut out, bg shows through: \(f.tr)")
        #expect(isMagenta(f.br), "inverted: right half is now cut out, bg shows through: \(f.br)")
    }

    @Test func disabledEffectLeavesClipUnmasked() async throws {
        let matteURL = try await Self.halfMatteVideoURL()
        var fg = CompositorFixtures.patternClip(id: "fg")
        var effect = personMaskEffect(matteURL: matteURL)
        effect.enabled = false
        fg.effects = [effect]

        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [fg])])
        let f = try await CompositorRenderTests.render(
            timeline, frame: 15, imageURLs: ["pattern": try await CompositorFixtures.patternVideoURL()]
        )
        #expect(isGreen(f.tr), "disabled effect: clip renders normally, no track lookup performed: \(f.tr)")
    }

    @Test func missingCacheFileFailsOpen() async throws {
        var fg = CompositorFixtures.patternClip(id: "fg")
        fg.effects = [personMaskEffect(matteURL: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID()).mov"))]

        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [fg])])
        let f = try await CompositorRenderTests.render(
            timeline, frame: 15, imageURLs: ["pattern": try await CompositorFixtures.patternVideoURL()]
        )
        #expect(isGreen(f.tr), "missing cache file: clip renders unmasked instead of failing: \(f.tr)")
    }
}
