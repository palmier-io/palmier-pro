import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Preview transform overlay")
struct TransformOverlayMathTests {
    @Test func rotatedMoveSnapsToBothCanvasAxes() {
        let start = Transform(
            centerX: 0.496,
            centerY: 0.51,
            width: 0.4,
            height: 0.2,
            rotation: 37
        )

        let result = TransformOverlayMath.movedTransform(
            start,
            by: .zero,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        #expect(result.transform.centerX == 0.5)
        #expect(result.transform.centerY == 0.5)
        #expect(result.guides.x)
        #expect(result.guides.y)
        #expect(result.transform.rotation == 37)
    }

    @Test func rotatedMoveReportsOnlyTheAlignedAxis() {
        let start = Transform(centerX: 0.496, centerY: 0.7, rotation: 90)

        let result = TransformOverlayMath.movedTransform(
            start,
            by: .zero,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        #expect(result.transform.centerX == 0.5)
        #expect(result.transform.centerY == 0.7)
        #expect(result.guides.x)
        #expect(!result.guides.y)
    }
}
