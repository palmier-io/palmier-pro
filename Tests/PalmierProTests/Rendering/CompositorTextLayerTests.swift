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

    private func backgroundTextClip(
        rotation: Double = 0,
        rotationX: Double = 0,
        rotationY: Double = 0
    ) -> Clip {
        var clip = textClip(" ")
        var style = clip.textStyle ?? TextStyle()
        style.color.a = 0
        style.background = .init(enabled: true, color: .init(r: 1, g: 1, b: 1, a: 1))
        clip.textStyle = style
        clip.transform = Transform(
            width: 0.6,
            height: 0.2,
            rotation: rotation,
            rotationX: rotationX,
            rotationY: rotationY
        )
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

    private func visibleBounds(_ frame: CompositorRenderTests.Frame) -> CGRect? {
        let height = frame.bytes.count / (frame.w * 4)
        var bounds = CGRect.null
        for y in 0..<height {
            for x in 0..<frame.w {
                let pixel = frame.at(x, y)
                if pixel.r + pixel.g + pixel.b > 30 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds.isNull ? nil : bounds
    }

    @Test func textCompositesOverVideo() async throws {
        let tl = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [textClip("HELLO")]),                       // track 0: top
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")]) // track 1: bottom
        )
        let f = try await CompositorRenderTests.render(tl, frame: 15, renderSize: Self.size)
        #expect(whiteInBand(f) > 30, "white text should composite over the video: \(whiteInBand(f))")
    }

    @Test func gaussianBlurSoftensTheCompleteTextLayer() async throws {
        let sharp = backgroundTextClip()
        var blurred = sharp
        blurred.textStyle?.blur = 60
        let sharpFrame = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [sharp])),
            frame: 15,
            renderSize: Self.size
        )
        let blurredFrame = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [blurred])),
            frame: 15,
            renderSize: Self.size
        )
        let sharpOutside = sharpFrame.at(60, 90)
        let blurredOutside = blurredFrame.at(60, 90)

        #expect(CompositorFixtures.isBlack(sharpOutside))
        #expect(blurredOutside.r + blurredOutside.g + blurredOutside.b > 30)
        #expect(blurredFrame.at(64, 90).r < sharpFrame.at(64, 90).r)
    }

    @Test func genericGaussianEffectDoesNotCreateASecondTextBlurSource() async throws {
        let sharp = backgroundTextClip()
        var effectBlurred = sharp
        effectBlurred.effects = [Effect.make("blur.gaussian", ["radius": 60])]
        let sharpFrame = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [sharp])),
            frame: 15,
            renderSize: Self.size
        )
        let effectFrame = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [effectBlurred])),
            frame: 15,
            renderSize: Self.size
        )

        #expect(effectFrame.bytes == sharpFrame.bytes)
    }

    @Test func invertedFillUsesWhiteDifferenceBlend() async throws {
        var text = textClip("HELLO")
        text.textFillMode = .inverted
        var style = text.textStyle ?? TextStyle()
        style.color = .init(r: 0.2, g: 0.4, b: 0.6, a: 1)
        style.fontScale = 4
        style.isBold = true
        style.border.enabled = true
        style.shadow.enabled = true
        style.background.enabled = true
        text.textStyle = style
        text.transform = Transform(topLeft: (0.05, 0.25), width: 0.9, height: 0.5)

        let background = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let composited = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let original = try await CompositorRenderTests.render(background, frame: 15, renderSize: Self.size)
        let inverted = try await CompositorRenderTests.render(composited, frame: 15, renderSize: Self.size)
        var invertedPixels = 0
        for y in 0..<Int(Self.size.height) {
            for x in 0..<Int(Self.size.width) {
                let source = original.at(x, y)
                let result = inverted.at(x, y)
                let matchesInverse = abs(result.r - (255 - source.r)) < 30
                    && abs(result.g - (255 - source.g)) < 30
                    && abs(result.b - (255 - source.b)) < 30
                if matchesInverse { invertedPixels += 1 }
            }
        }

        #expect(invertedPixels > 100)
        #expect(inverted.tl == original.tl)
        #expect(inverted.tr == original.tr)
    }

    @Test func invertedFillPreservesBackgroundPaddingLayout() async throws {
        var normal = textClip("HELLO")
        var style = normal.textStyle ?? TextStyle()
        style.alignment = .left
        style.background = .init(
            enabled: true,
            color: .init(r: 0, g: 0, b: 0, a: 0),
            paddingX: 80,
            paddingY: 30
        )
        normal.textStyle = style
        normal.transform = Transform(topLeft: (0.05, 0.25), width: 0.9, height: 0.5)
        var inverted = normal
        inverted.textFillMode = .inverted

        let normalFrame = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [normal])),
            frame: 15,
            renderSize: Self.size
        )
        let invertedFrame = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [inverted])),
            frame: 15,
            renderSize: Self.size
        )

        let normalBounds = try #require(visibleBounds(normalFrame))
        let invertedBounds = try #require(visibleBounds(invertedFrame))
        #expect(abs(invertedBounds.minX - normalBounds.minX) <= 1)
        #expect(abs(invertedBounds.minY - normalBounds.minY) <= 1)
        #expect(abs(invertedBounds.width - normalBounds.width) <= 1)
        #expect(abs(invertedBounds.height - normalBounds.height) <= 1)
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

    @Test func textUsesXTiltRotation() async throws {
        let timeline = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [backgroundTextClip(rotationX: 60)])
        )
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(CompositorFixtures.isWhite(frame.at(160, 90)))
        #expect(CompositorFixtures.isBlack(frame.at(160, 75)))
    }

    @Test func textUsesYTiltRotation() async throws {
        let timeline = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [backgroundTextClip(rotationY: 60)])
        )
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(CompositorFixtures.isWhite(frame.at(160, 90)))
        #expect(CompositorFixtures.isBlack(frame.at(90, 90)))
    }

    @Test func tiltedTextSamplesZRotationKeyframes() async throws {
        var text = backgroundTextClip(rotationX: 60)
        text.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0),
            Keyframe(frame: 30, value: 90),
        ])
        let timeline = CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [text]))

        let horizontal = try await CompositorRenderTests.render(timeline, frame: 0, renderSize: Self.size)
        let vertical = try await CompositorRenderTests.render(timeline, frame: 30, renderSize: Self.size)

        #expect(CompositorFixtures.isBlack(horizontal.at(160, 75)))
        #expect(CompositorFixtures.isWhite(vertical.at(160, 75)))
    }

    @Test func tiltedTextMatchesProjectedClipCorners() async throws {
        var text = backgroundTextClip(rotation: 25, rotationX: 30, rotationY: -45)
        text.transform.centerX = 0.25
        text.transform.centerY = 0.35
        text.effects = [Effect.make("color.exposure", ["ev": 0.25])]
        let timeline = CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [text]))
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)
        let rect = CGRect(x: -16, y: 45, width: 192, height: 36)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corners = TextTiltGeometry.corners(
            of: rect,
            around: center,
            transform: text.transform,
            canvasSize: Self.size
        )

        for corner in [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft] {
            let inside = CGPoint(
                x: corner.x * 0.8 + center.x * 0.2,
                y: corner.y * 0.8 + center.y * 0.2
            )
            #expect(CompositorFixtures.isWhite(frame.at(Int(inside.x), Int(inside.y))))
        }
    }

    @Test func offCanvasTextCanRotateIntoTheFinalFrame() async throws {
        var text = backgroundTextClip(rotation: -90, rotationY: 30)
        text.transform.centerX = 0
        let timeline = CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [text]))

        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(CompositorFixtures.isWhite(frame.at(10, 130)))
    }

    @Test func oversizedTiltKeepsAValidProjectedQuad() {
        let center = CGPoint(x: 160, y: 90)
        let corners = TextTiltGeometry.corners(
            of: CGRect(x: -1_120, y: -270, width: 2_560, height: 720),
            around: center,
            transform: Transform(width: 8, height: 4, rotationX: 75, rotationY: 89),
            canvasSize: Self.size
        )

        #expect(corners.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(corners.contains(center))
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
        text.setTextFillMode(.footage)
        let timeline = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(!CompositorFixtures.isBlack(frame.at(160, 30)))
        #expect(CompositorFixtures.isBlack(frame.at(80, 90)))
    }

    @Test func footageFillUsesTextTiltRotation() async throws {
        var text = backgroundTextClip(rotationY: 60)
        text.setTextFillMode(.footage)
        let timeline = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let frame = try await CompositorRenderTests.render(timeline, frame: 15, renderSize: Self.size)

        #expect(!CompositorFixtures.isBlack(frame.at(160, 90)))
        #expect(CompositorFixtures.isBlack(frame.at(90, 90)))
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

    @Test func footageFillUsesTextColorForTheMatte() async throws {
        let frame = try await renderFootageFill(
            opacity: 1,
            matteColor: .init(r: 0, g: 1, b: 0, a: 1)
        )

        #expect(CompositorFixtures.isGreen(frame.tl), "outside glyphs should use the text color: \(frame.tl)")
        #expect(patternPixelsInTextBand(frame) > 80)
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

    private func renderFootageFill(
        opacity: Double,
        matteColor: TextStyle.RGBA = .init(r: 0, g: 0, b: 0, a: 1)
    ) async throws -> CompositorRenderTests.Frame {
        var text = textClip("HELLO")
        text.opacity = opacity
        var style = text.textStyle ?? TextStyle()
        style.fontScale = 4
        style.isBold = true
        style.color = matteColor
        text.textStyle = style
        text.setTextFillMode(.footage, footageMatteColor: matteColor)
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
