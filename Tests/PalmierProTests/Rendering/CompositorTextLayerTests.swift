import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

/// Text is a compositor layer (Path B): it composites through CustomVideoCompositor and
/// obeys timeline track z-order, rather than being stamped on top by a post-process tool.
@Suite("Compositor — text layer")
@MainActor
struct CompositorTextLayerTests {
    static let size = CompositorFixtures.renderSize  // 320×180

    private func textClip(_ content: String) -> Clip {
        var c = Fixtures.clip(id: "txt", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        c.textContent = content
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.shadow.enabled = false
        style.fontScale = 2
        c.textStyle = style
        // A band over the left-center, where the pattern is red (top) / blue (bottom) —
        // never white — so any white pixel there is unambiguously text.
        c.transform = Transform(topLeft: (0.1, 0.4), width: 0.8, height: 0.25)
        return c
    }

    private func backgroundTextClip(rotation: Double = 0) -> Clip {
        var clip = textClip(" ")
        var style = clip.textStyle ?? TextStyle()
        style.color.a = 0
        style.background = .init(enabled: true, color: .init(r: 1, g: 1, b: 1, a: 1))
        clip.textStyle = style
        clip.transform = Transform(width: 0.6, height: 0.2, rotation: rotation)
        return clip
    }

    /// White pixels in the discriminating band (x 40–150, y 72–108).
    private func whiteInBand(_ f: CompositorRenderTests.Frame) -> Int {
        var n = 0
        for y in 72..<108 {
            for x in 40..<150 {
                let p = f.at(x, y)
                if p.r > 200, p.g > 200, p.b > 200 { n += 1 }
            }
        }
        return n
    }

    @Test func textCompositesOverVideo() async throws {
        let tl = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [textClip("HELLO")]),                       // track 0: top
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")]) // track 1: bottom
        )
        let f = try await CompositorRenderTests.render(tl, frame: 15, renderSize: Self.size)
        #expect(whiteInBand(f) > 30, "white text should composite over the video: \(whiteInBand(f))")
    }

    @Test func textObeysTrackZOrder() async throws {
        // Same two layers, but the opaque full-frame video is on top → it must hide the text.
        let behind = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")]), // track 0: top
            Fixtures.videoTrack(clips: [textClip("HELLO")])                         // track 1: bottom
        )
        let f = try await CompositorRenderTests.render(behind, frame: 15, renderSize: Self.size)
        #expect(whiteInBand(f) == 0, "text behind an opaque video must be hidden: \(whiteInBand(f))")
    }

    @Test func textUsesVideoCanvasRotation() async throws {
        let timeline = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [backgroundTextClip(rotation: 90)])
        )
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(CompositorFixtures.isWhite(frame.at(160, 30)))
        #expect(CompositorFixtures.isBlack(frame.at(80, 90)))
    }

    @Test func textRotationSamplesKeyframes() async throws {
        var text = backgroundTextClip()
        text.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0, interpolationOut: .linear),
            Keyframe(frame: 30, value: 90, interpolationOut: .linear),
        ])
        let timeline = CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [text]))

        let horizontal = try await CompositorRenderTests.render(timeline, frame: 0, renderSize: Self.size)
        let vertical = try await CompositorRenderTests.render(timeline, frame: 30, renderSize: Self.size)

        #expect(CompositorFixtures.isWhite(horizontal.at(80, 90)))
        #expect(CompositorFixtures.isBlack(horizontal.at(160, 30)))
        #expect(CompositorFixtures.isWhite(vertical.at(160, 30)))
        #expect(CompositorFixtures.isBlack(vertical.at(80, 90)))
    }

    @Test func textRenderingUsesFrameResolvedTransform() async throws {
        var text = backgroundTextClip()
        text.transform = Transform(centerX: 0.2, centerY: 0.2, width: 0.2, height: 0.1)
        text.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 30, value: AnimPair(a: 0.65, b: 0.2)),
        ])
        text.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 30, value: AnimPair(a: 0.2, b: 0.4)),
        ])
        text.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 30, value: 90),
        ])
        let timeline = CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [text]))

        let frame = try await CompositorRenderTests.render(timeline, frame: 30, renderSize: Self.size)

        #expect(CompositorFixtures.isWhite(frame.at(240, 72)))
        #expect(CompositorFixtures.isBlack(frame.at(64, 36)))
    }

    @Test func footageFillUsesTextRotation() async throws {
        var text = backgroundTextClip(rotation: 90)
        text.textFillMode = .footage
        let timeline = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(!CompositorFixtures.isBlack(frame.at(160, 30)))
        #expect(CompositorFixtures.isBlack(frame.at(80, 90)))
    }

    @Test func footageFillStencilsVideoThroughGlyphs() async throws {
        let f = try await renderFootageFill(opacity: 1)

        #expect(CompositorFixtures.isBlack(f.tl), "outside glyphs should be black: \(f.tl)")
        #expect(CompositorFixtures.isBlack(f.tr), "outside glyphs should be black: \(f.tr)")
        #expect(CompositorFixtures.isBlack(f.bl), "outside glyphs should be black: \(f.bl)")
        #expect(CompositorFixtures.isBlack(f.br), "outside glyphs should be black: \(f.br)")

        let patternPixels = patternPixelsInTextBand(f)
        #expect(patternPixels > 80, "footage should show through glyphs: \(patternPixels)")
    }

    @Test func footageFillOpacityCrossfadesStencil() async throws {
        let opaque = try await renderFootageFill(opacity: 1)
        let mid = try await renderFootageFill(opacity: 0.5)
        let clear = try await renderFootageFill(opacity: 0)

        #expect(CompositorFixtures.isBlack(opaque.tl), "full opacity blacks outside glyphs: \(opaque.tl)")
        #expect(!CompositorFixtures.isBlack(mid.tl), "partial opacity should keep outside-glyph color: \(mid.tl)")
        #expect(CompositorFixtures.isRed(clear.tl), "zero opacity leaves the full frame: \(clear.tl)")
        #expect(mid.tl.r > opaque.tl.r && mid.tl.r < clear.tl.r,
                "corner red should sit between stenciled and full: \(mid.tl) vs \(opaque.tl)/\(clear.tl)")
    }

    private func renderFootageFill(opacity: Double) async throws -> CompositorRenderTests.Frame {
        var text = textClip("HELLO")
        text.textFillMode = .footage
        text.opacity = opacity
        var style = text.textStyle ?? TextStyle()
        style.fontScale = 4
        style.isBold = true
        text.textStyle = style
        text.transform = Transform(topLeft: (0.05, 0.25), width: 0.9, height: 0.5)

        let tl = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        return try await CompositorRenderTests.render(tl, frame: 15, renderSize: Self.size)
    }

    private func patternPixelsInTextBand(_ f: CompositorRenderTests.Frame) -> Int {
        var n = 0
        for y in 60..<120 {
            for x in 20..<300 {
                let p = f.at(x, y)
                if CompositorFixtures.isRed(p) || CompositorFixtures.isGreen(p)
                    || CompositorFixtures.isBlue(p) || CompositorFixtures.isWhite(p) {
                    n += 1
                }
            }
        }
        return n
    }

}
