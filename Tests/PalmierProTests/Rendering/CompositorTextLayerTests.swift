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
        c.transform = Transform(topLeft: (0.1, 0.4), width: 0.8, height: 0.2)
        return c
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

    @Test func footageFillStencilsVideoThroughGlyphs() async throws {
        var text = textClip("HELLO")
        text.textFillMode = .footage
        var style = text.textStyle ?? TextStyle()
        style.fontScale = 4
        style.isBold = true
        text.textStyle = style
        text.transform = Transform(topLeft: (0.05, 0.25), width: 0.9, height: 0.5)

        let tl = CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bg")])
        )
        let f = try await CompositorRenderTests.render(tl, frame: 15, renderSize: Self.size)

        // Corners sit outside letter strokes → transparent stencil → black clear color.
        #expect(CompositorFixtures.isBlack(f.tl), "outside glyphs should be black: \(f.tl)")
        #expect(CompositorFixtures.isBlack(f.tr), "outside glyphs should be black: \(f.tr)")
        #expect(CompositorFixtures.isBlack(f.bl), "outside glyphs should be black: \(f.bl)")
        #expect(CompositorFixtures.isBlack(f.br), "outside glyphs should be black: \(f.br)")

        // Inside the text band, stencil reveals pattern quadrants (BR is white in the fixture).
        var patternPixels = 0
        for y in 60..<120 {
            for x in 20..<300 {
                let p = f.at(x, y)
                if CompositorFixtures.isRed(p) || CompositorFixtures.isGreen(p)
                    || CompositorFixtures.isBlue(p) || CompositorFixtures.isWhite(p) {
                    patternPixels += 1
                }
            }
        }
        #expect(patternPixels > 80, "footage should show through glyphs: \(patternPixels)")
    }

}
