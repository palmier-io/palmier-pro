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

}
