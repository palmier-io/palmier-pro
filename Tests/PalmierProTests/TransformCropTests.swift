import Testing
@testable import PalmierPro

@Suite("Transform")
struct TransformTests {

    // MARK: - Geometry derivations

    @Test func topLeftIsCenterMinusHalfSize() {
        let t = Transform(centerX: 0.6, centerY: 0.4, width: 0.4, height: 0.2)
        #expect(abs(t.topLeft.x - 0.4) < 1e-9) // 0.6 - 0.2
        #expect(abs(t.topLeft.y - 0.3) < 1e-9) // 0.4 - 0.1
    }

    @Test func centerInitializerComputesCenterX() {
        let t = Transform(center: (x: 0.7, y: 0.3), width: 0.2, height: 0.2)
        #expect(t.centerX == 0.7)
        #expect(t.centerY == 0.3)
    }

    @Test func topLeftInitializerComputesCenter() {
        let t = Transform(topLeft: (x: 0.2, y: 0.4), width: 0.4, height: 0.2)
        #expect(t.centerX == 0.4)  // 0.2 + 0.2
        #expect(t.centerY == 0.5)  // 0.4 + 0.1
    }

    // MARK: - snapToBoundary

    @Test func snapToBoundaryClampsToZeroWithinThreshold() {
        #expect(Transform.snapToBoundary(0.01, threshold: 0.05) == 0)
        #expect(Transform.snapToBoundary(-0.01, threshold: 0.05) == 0)
    }

    @Test func snapToBoundaryClampsToOneWithinThreshold() {
        #expect(Transform.snapToBoundary(0.97, threshold: 0.05) == 1)
        #expect(Transform.snapToBoundary(1.02, threshold: 0.05) == 1)
    }

    @Test func snapToBoundaryLeavesMidRangeAlone() {
        #expect(Transform.snapToBoundary(0.5, threshold: 0.05) == 0.5)
        #expect(Transform.snapToBoundary(0.1, threshold: 0.05) == 0.1)
    }

    // MARK: - snapToCanvasEdges

    @Test func snapToCanvasEdgesSnapsLeftEdgeWhenNearZero() {
        // centerX=0.252, width=0.5 → topLeft.x=0.002. Threshold 0.05 snaps left to 0 → centerX=0.25.
        var t = Transform(centerX: 0.252, centerY: 0.5, width: 0.5, height: 0.5)
        t.snapToCanvasEdges(threshold: 0.05)
        #expect(abs(t.centerX - 0.25) < 1e-9)
    }

    @Test func snapToCanvasEdgesSnapsRightEdgeWhenNearOne() {
        // centerX=0.748, width=0.5 → right=0.998. Snap right to 1 → centerX=0.75.
        var t = Transform(centerX: 0.748, centerY: 0.5, width: 0.5, height: 0.5)
        t.snapToCanvasEdges(threshold: 0.05)
        #expect(abs(t.centerX - 0.75) < 1e-9)
    }

    @Test func snapToCanvasEdgesLeavesCenteredTransformAlone() {
        var t = Transform(centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.4)
        t.snapToCanvasEdges(threshold: 0.05)
        #expect(t.centerX == 0.5)
        #expect(t.centerY == 0.5)
    }

    // MARK: - snapCenterToCanvasCenter

    @Test func snapCenterToCanvasCenterSnapsWithinThreshold() {
        var t = Transform(centerX: 0.51, centerY: 0.49)
        let (x, y) = t.snapCenterToCanvasCenter(thresholdH: 0.05, thresholdV: 0.05)
        #expect(t.centerX == 0.5)
        #expect(t.centerY == 0.5)
        #expect(x == true)
        #expect(y == true)
    }

    @Test func snapCenterToCanvasCenterReportsPerAxisSnap() {
        // Only X is within threshold.
        var t = Transform(centerX: 0.51, centerY: 0.7)
        let (x, y) = t.snapCenterToCanvasCenter(thresholdH: 0.05, thresholdV: 0.05)
        #expect(t.centerX == 0.5)
        #expect(t.centerY == 0.7) // unchanged
        #expect(x == true)
        #expect(y == false)
    }
}

@Suite("Crop")
struct CropTests {

    @Test func identityCropHasAllZeroInsets() {
        #expect(Crop().isIdentity)
        #expect(!Crop(left: 0.1).isIdentity)
        #expect(!Crop(top: 0.1).isIdentity)
        #expect(!Crop(right: 0.1).isIdentity)
        #expect(!Crop(bottom: 0.1).isIdentity)
    }

    @Test func visibleFractionsSubtractInsets() {
        let crop = Crop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4)
        // 1 - 0.1 - 0.3 = 0.6; 1 - 0.2 - 0.4 = 0.4
        #expect(abs(crop.visibleWidthFraction - 0.6) < 1e-9)
        #expect(abs(crop.visibleHeightFraction - 0.4) < 1e-9)
    }

    @Test func visibleFractionsClampNegativeToZero() {
        // Insets sum > 1 — visible region collapsed to zero (not negative).
        let crop = Crop(left: 0.6, top: 0.5, right: 0.6, bottom: 0.6)
        #expect(crop.visibleWidthFraction == 0)
        #expect(crop.visibleHeightFraction == 0)
    }
}

@Suite("CropAspectLock")
struct CropAspectLockTests {

    @Test func freeAndOriginalHaveNoFixedAspect() {
        #expect(CropAspectLock.free.pixelAspect == nil)
        #expect(CropAspectLock.original.pixelAspect == nil)
    }

    @Test func namedAspectsProduceExpectedRatios() {
        #expect(CropAspectLock.r1x1.pixelAspect == 1.0)
        #expect(CropAspectLock.r16x9.pixelAspect == 16.0 / 9.0)
        #expect(CropAspectLock.r9x16.pixelAspect == 9.0 / 16.0)
        #expect(CropAspectLock.r4x3.pixelAspect == 4.0 / 3.0)
        #expect(CropAspectLock.r3x4.pixelAspect == 3.0 / 4.0)
        #expect(CropAspectLock.r21x9.pixelAspect == 21.0 / 9.0)
    }

    @Test func allCasesAreEnumerable() {
        // Pinning down the case list so anyone adding a case has to update label/pixelAspect too.
        #expect(CropAspectLock.allCases.count == 8)
    }
}
