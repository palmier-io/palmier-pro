import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

/// Absolute correctness tests for the CI compositor — asserts expected output directly
/// (not "matches the old renderer"), so it stands on its own once the stock path is gone.
/// Covers the matrix the old parity tests did: transform, crop, flip, opacity, fades,
/// keyframes, multi-track stacking, alpha, gaps, hidden tracks, speed, render size, cuts.
@Suite("Compositor — render output")
@MainActor
struct CompositorRenderTests {

    static let size = CompositorFixtures.renderSize  // 320×180

    /// Sampled frame with quadrant/center color classification.
    struct Frame {
        let bytes: [UInt8]
        let w: Int
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        // Quadrant + center sample points for a 320×180 frame.
        var tl: (r: Int, g: Int, b: Int) { at(80, 45) }
        var tr: (r: Int, g: Int, b: Int) { at(240, 45) }
        var bl: (r: Int, g: Int, b: Int) { at(80, 135) }
        var br: (r: Int, g: Int, b: Int) { at(240, 135) }
        var center: (r: Int, g: Int, b: Int) { at(w / 2, bytes.count / (4 * w) / 2) }
    }

    static func render(
        _ timeline: Timeline, frame: Int,
        renderSize: CGSize = size, imageURLs: [String: URL] = [:]
    ) async throws -> Frame {
        var urls = imageURLs
        if urls["pattern"] == nil { urls["pattern"] = try await CompositorFixtures.patternVideoURL() }
        nonisolated(unsafe) let resolved = urls
        let result = try await CompositionBuilder.build(
            timeline: timeline, resolveURL: { resolved[$0] }, renderSize: renderSize
        )
        let gen = AVAssetImageGenerator(asset: result.composition)
        gen.videoComposition = result.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(
            at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
        ).image
        return Frame(bytes: ColorProbeHelpers.srgbBytes(cg, size: renderSize), w: Int(renderSize.width))
    }
}

// MARK: - Color classification

private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 140 && p.g < 100 && p.b < 100 }
private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 140 && p.r < 110 && p.b < 110 }
private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 140 && p.r < 100 && p.g < 100 }
private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g > 170 && p.b > 170 }
private func isBlack(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r < 45 && p.g < 45 && p.b < 45 }

// MARK: - Tests

extension CompositorRenderTests {

    @Test func identityQuadrants() async throws {
        let tl = Self.timelineWith(Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()]))
        let f = try await Self.render(tl, frame: 15)
        #expect(isRed(f.tl), "TL \(f.tl)")
        #expect(isGreen(f.tr), "TR \(f.tr)")
        #expect(isBlue(f.bl), "BL \(f.bl)")
        #expect(isWhite(f.br), "BR \(f.br)")
    }

    @Test func flipHorizontalSwapsLeftRight() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.transform = Transform(flipHorizontal: true)
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15)
        #expect(isGreen(f.tl), "TL should be green (was TR): \(f.tl)")
        #expect(isRed(f.tr), "TR should be red (was TL): \(f.tr)")
    }

    @Test func flipVerticalSwapsTopBottom() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.transform = Transform(flipVertical: true)
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15)
        #expect(isBlue(f.tl), "TL should be blue (was BL): \(f.tl)")
        #expect(isRed(f.bl), "BL should be red (was TL): \(f.bl)")
    }

    @Test func rotationLeavesCornersBlack() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.transform = Transform(width: 0.6, height: 0.6, rotation: 45)
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15)
        #expect(isBlack(f.at(5, 5)), "corner should be black behind a rotated clip: \(f.at(5, 5))")
        #expect(!isBlack(f.at(160, 90)), "center should have content: \(f.at(160, 90))")
    }

    @Test func pipOverBackground() async throws {
        var pip = CompositorFixtures.patternClip(id: "pip")
        pip.transform = Transform(centerX: 0.3, centerY: 0.35, width: 0.5, height: 0.5)
        let tl = Self.timelineWith(
            Fixtures.videoTrack(clips: [pip]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let f = try await Self.render(tl, frame: 15)
        // Far from the PiP (bottom-right) the background shows through: its BR quadrant is white.
        #expect(isWhite(f.at(300, 170)), "bg should fill behind/around the PiP: \(f.at(300, 170))")
    }

    @Test func cropLeftRevealsBlack() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.crop = Crop(left: 0.4, top: 0, right: 0, bottom: 0)  // crop 40% off the left
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15)
        #expect(isBlack(f.at(10, 90)), "cropped-away left strip should be black: \(f.at(10, 90))")
        #expect(!isBlack(f.at(300, 45)), "right side should still show content: \(f.at(300, 45))")
    }

    @Test func cropKeyframedMidway() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop(), interpolationOut: .linear),
            Keyframe(frame: 60, value: Crop(left: 0.6, top: 0, right: 0, bottom: 0), interpolationOut: .linear),
        ])
        // At frame 30 the left crop is ~0.3 → left strip black, center still content.
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 30)
        #expect(isBlack(f.at(10, 90)), "keyframed crop should blacken the left edge: \(f.at(10, 90))")
        #expect(!isBlack(f.at(300, 90)), "right side should still show content: \(f.at(300, 90))")
    }

    @Test func opacityHalfOverBlack() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.opacity = 0.5
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15)
        // TL red (~233) at half opacity over black → roughly half brightness, still red-dominant.
        #expect(f.tl.r > 70 && f.tl.r < 175, "TL red should be ~half: \(f.tl)")
        #expect(f.tl.g < 90 && f.tl.b < 90, "TL should stay red-dominant: \(f.tl)")
    }

    @Test func opacityKeyframedDims() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0, interpolationOut: .smooth),
            Keyframe(frame: 60, value: 0.0, interpolationOut: .smooth),
        ])
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 30)
        // Halfway through a 1→0 fade: dimmer than full red, not yet black.
        #expect(f.tl.r > 60 && f.tl.r < 210, "TL should be partially dimmed: \(f.tl)")
    }

    @Test func fadeInMidwayDims() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.fadeInFrames = 30
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15)
        // ~50% through a linear fade-in over black.
        #expect(f.tl.r > 60 && f.tl.r < 190, "TL should be mid-fade: \(f.tl)")
    }

    @Test func transformKeyframedPlacesClip() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 1, b: 1), interpolationOut: .linear),
            Keyframe(frame: 60, value: AnimPair(a: 0.5, b: 0.5), interpolationOut: .linear),
        ])
        clip.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0, b: 0), interpolationOut: .linear),
            Keyframe(frame: 60, value: AnimPair(a: 0.5, b: 0.5), interpolationOut: .linear),
        ])
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 59)
        // Near-fully scaled to ~0.5 at top-left offset ~0.5 → clip sits bottom-right; top-left is black.
        #expect(isBlack(f.at(10, 10)), "top-left should be black after the clip moves away: \(f.at(10, 10))")
        #expect(!isBlack(f.at(280, 160)), "clip should be placed bottom-right: \(f.at(280, 160))")
    }

    @Test func imageClipRenders() async throws {
        let png = try CompositorFixtures.patternPNG(size: Self.size)
        let clip = Fixtures.clip(id: "img", mediaRef: "pattern-image", mediaType: .image, start: 0, duration: 60)
        let f = try await Self.render(
            Self.timelineWith(Fixtures.videoTrack(clips: [clip])),
            frame: 15, imageURLs: ["pattern-image": png]
        )
        #expect(isRed(f.tl) && isWhite(f.br), "image source should render the pattern: \(f.tl) \(f.br)")
    }

    @Test func gapIsBlack() async throws {
        let tl = Self.timelineWith(Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(start: 30, duration: 30)]))
        let f = try await Self.render(tl, frame: 10)
        #expect(isBlack(f.tl) && isBlack(f.center), "frame before the clip should be black: \(f.tl)")
    }

    @Test func hiddenTrackSkipped() async throws {
        var hidden = Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "hid")])
        hidden.hidden = true
        var bg = CompositorFixtures.patternClip(id: "bg")
        bg.transform = Transform(flipVertical: true)  // distinguishable from the hidden one
        let f = try await Self.render(Self.timelineWith(hidden, Fixtures.videoTrack(clips: [bg])), frame: 15)
        // Hidden track ignored → we see the flipped bg: TL is blue (bg's BL flipped up).
        #expect(isBlue(f.tl), "hidden track should be skipped, flipped bg shows: \(f.tl)")
    }

    @Test func speedDoubleStillRenders() async throws {
        var fast = CompositorFixtures.patternClip()
        fast.speed = 2.0
        let f = try await Self.render(Self.timelineWith(Fixtures.videoTrack(clips: [fast])), frame: 15)
        #expect(isRed(f.tl) && isGreen(f.tr), "sped-up clip should still render the pattern: \(f.tl) \(f.tr)")
    }

    @Test func nonNativeRenderSizeQuadrants() async throws {
        let tl = Self.timelineWith(Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()]))
        let f = try await Self.render(tl, frame: 15, renderSize: CGSize(width: 640, height: 360))
        #expect(isRed(f.at(160, 90)), "TL quadrant at 640×360: \(f.at(160, 90))")
        #expect(isWhite(f.at(480, 270)), "BR quadrant at 640×360: \(f.at(480, 270))")
    }

    @Test func topLayerWinsInStack() async throws {
        // Opaque full-frame top over a flipped bg → top wins everywhere.
        var top = CompositorFixtures.patternClip(id: "top")
        var bg = CompositorFixtures.patternClip(id: "bg")
        bg.transform = Transform(flipHorizontal: true)
        let f = try await Self.render(Self.timelineWith(
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [bg])
        ), frame: 15)
        _ = top
        #expect(isRed(f.tl), "opaque top layer should win: TL red, not flipped-bg green: \(f.tl)")
    }

    @Test func alphaMediaShowsBackgroundThrough() async throws {
        // Half-transparent overlay (top-left filled, rest clear) over an opaque pattern bg.
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("render-alpha.png")
        if !FileManager.default.fileExists(atPath: pngURL.path) {
            let w = 320, h = 180
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))  // opaque red TL only
            let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        let overlay = Fixtures.clip(id: "ov", mediaRef: "alpha-img", mediaType: .image, start: 0, duration: 60)
        let f = try await Self.render(Self.timelineWith(
            Fixtures.videoTrack(clips: [overlay]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        ), frame: 15, imageURLs: ["alpha-img": pngURL])
        #expect(isRed(f.tl), "opaque overlay region shows red: \(f.tl)")
        #expect(isWhite(f.br), "transparent overlay region shows bg through: \(f.br)")
    }

    @Test func adjacentClipsBothRender() async throws {
        var second = CompositorFixtures.patternClip(id: "c2", start: 30, duration: 30)
        second.transform = Transform(flipHorizontal: true)
        let tl = Self.timelineWith(Fixtures.videoTrack(clips: [
            CompositorFixtures.patternClip(id: "c1", duration: 30), second,
        ]))
        let a = try await Self.render(tl, frame: 29)   // first clip
        let b = try await Self.render(tl, frame: 31)   // second clip (flipped)
        #expect(isRed(a.tl), "first clip TL red: \(a.tl)")
        #expect(isGreen(b.tl), "second (flipped) clip TL green: \(b.tl)")
    }
}

// MARK: - Fixture helper

extension CompositorRenderTests {
    static func timelineWith(_ tracks: Track...) -> Timeline {
        var t = Fixtures.timeline(tracks: tracks)
        t.width = Int(size.width)
        t.height = Int(size.height)
        return t
    }
}
