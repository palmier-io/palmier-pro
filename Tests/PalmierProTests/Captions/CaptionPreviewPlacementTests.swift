import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Caption preview placement")
struct CaptionPreviewPlacementTests {
    @Test func dragTranslationUsesNormalizedCanvasCoordinatesAndSnapsToCenter() {
        let center = CaptionPreviewPlacement.movedCenter(
            from: CGPoint(x: 0.4, y: 0.6),
            by: CGSize(width: 20, height: -20),
            in: CGSize(width: 200, height: 200)
        )

        #expect(center == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func dragTranslationAllowsOffCanvasPlacement() {
        let center = CaptionPreviewPlacement.movedCenter(
            from: CGPoint(x: 0.9, y: 0.1),
            by: CGSize(width: 50, height: -50),
            in: CGSize(width: 100, height: 100)
        )

        #expect(abs(center.x - 1.4) < 0.000_001)
        #expect(abs(center.y + 0.4) < 0.000_001)
    }

    @Test func invalidCanvasSizeLeavesCenterUnchanged() {
        let start = CGPoint(x: 0.3, y: 0.7)

        #expect(CaptionPreviewPlacement.movedCenter(
            from: start,
            by: CGSize(width: 20, height: 20),
            in: .zero
        ) == start)
    }

    @Test func viewOffsetMovesCenteredRasterToPreviewPosition() {
        let offset = CaptionPreviewPlacement.viewOffset(
            for: CGPoint(x: 1.4, y: -0.4),
            in: CGSize(width: 200, height: 200)
        )

        #expect(abs(offset.width - 180) < 0.000_001)
        #expect(abs(offset.height + 180) < 0.000_001)
    }

    @Test func equivalentSyntheticPreviewClipsHaveStableIdentity() {
        let first = CaptionPreviewRender.clip(
            content: "Preview",
            style: .caption,
            transform: Transform(),
            preset: .none,
            highlight: nil
        )
        let second = CaptionPreviewRender.clip(
            content: "Preview",
            style: .caption,
            transform: Transform(),
            preset: .none,
            highlight: nil
        )

        #expect(first == second)
    }
}
