import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Canvas viewing overlays")
struct CanvasViewingOverlayTests {
    @Test func gridPresetsProvideTwoThroughFiveDivisions() {
        #expect(CanvasGridOverlay.allCases.map(\.rawValue) == [2, 3, 4, 5])
    }

    @Test(arguments: CanvasGridOverlay.allCases)
    func gridPositionsCreateOneFewerLineThanDivisions(grid: CanvasGridOverlay) {
        #expect(grid.linePositions.count == grid.rawValue - 1)
        #expect(grid.linePositions.allSatisfy { $0 > 0 && $0 < 1 })
    }

    @Test func safeZoneInsetsMatchActionAndTitleStandards() {
        #expect(CanvasGuideOverlay.actionSafe.safeZoneInset == 0.035)
        #expect(CanvasGuideOverlay.titleSafe.safeZoneInset == 0.05)
        #expect(CanvasGuideOverlay.center.safeZoneInset == nil)
    }

    @Test(arguments: CanvasFormatOverlay.allCases)
    func formatReferenceIsCenteredAndPreservesItsAspect(format: CanvasFormatOverlay) {
        let canvas = CGSize(width: 1_920, height: 1_080)
        let rect = format.contentRect(in: canvas)

        #expect(abs(rect.midX - canvas.width / 2) < 0.0001)
        #expect(abs(rect.midY - canvas.height / 2) < 0.0001)
        #expect(abs(rect.width / rect.height - format.aspectRatio) < 0.0001)
        #expect(rect.minX >= 0 && rect.minY >= 0)
        #expect(rect.maxX <= canvas.width && rect.maxY <= canvas.height)
    }

    @Test func matchingFormatHasNoOutsideMask() {
        let size = CGSize(width: 1_080, height: 1_080)
        let contentRect = CanvasFormatOverlay.square.contentRect(in: size)

        #expect(CanvasOverlayGeometry.outsideRects(around: contentRect, in: size).isEmpty)
    }

    @Test func clearingSelectionRemovesEveryOverlayCategory() {
        var selection = CanvasOverlaySelection(
            grid: .three,
            guides: [.actionSafe, .center],
            format: .scope
        )

        selection.clear()

        #expect(selection.isEmpty)
    }
}
