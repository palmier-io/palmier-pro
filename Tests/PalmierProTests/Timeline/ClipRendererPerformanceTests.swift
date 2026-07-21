import CoreGraphics
import Testing
@testable import PalmierPro

@Suite struct ClipRendererPerformanceTests {
    @Test func compactSelectedClipsRenderWithinInteractionBudget() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 1_000,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let clip = Fixtures.clip(
            id: "caption",
            mediaRef: "caption-media",
            mediaType: .text,
            start: 0,
            duration: 30
        )

        let duration = ContinuousClock().measure {
            for index in 0..<50_000 {
                ClipRenderer.draw(
                    clip,
                    type: .text,
                    in: CGRect(x: CGFloat(index % 1_000), y: 0, width: 0.5, height: 64),
                    isSelected: true,
                    context: context,
                    displayName: "Caption",
                    fps: 30
                )
            }
        }

        #expect(duration < .seconds(2))
    }
}
