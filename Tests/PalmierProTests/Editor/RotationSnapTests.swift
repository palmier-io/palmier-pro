import Testing
@testable import PalmierPro

@Suite("Inspector rotation snapping")
struct RotationSnapTests {
    @Test(arguments: [
        (-4.0, 0.0),
        (4.0, 0.0),
        (86.0, 90.0),
        (94.0, 90.0),
        (176.0, 180.0),
        (184.0, 180.0),
        (266.0, 270.0),
        (274.0, 270.0),
        (356.0, 360.0),
        (-94.0, -90.0),
    ]) func rotationsNearAxesSnap(rotation: Double, expected: Double) {
        #expect(RotationSnap.adjusted(rotation) == expected)
    }

    @Test(arguments: [
        4.01,
        85.99,
        94.01,
        175.99,
        184.01,
        265.99,
        274.01,
    ]) func rotationsOutsideToleranceRemainExact(rotation: Double) {
        #expect(RotationSnap.adjusted(rotation) == rotation)
    }

    @Test(arguments: [0.0, 90.0, 180.0, 270.0, 360.0, -90.0])
    func axisAlignedRotationsShowGuides(rotation: Double) {
        #expect(RotationSnap.isAxisAligned(rotation))
    }

    @Test(arguments: [0.01, 89.99, 179.99, 269.99, .infinity, .nan])
    func otherRotationsHideGuides(rotation: Double) {
        #expect(!RotationSnap.isAxisAligned(rotation))
    }
}
