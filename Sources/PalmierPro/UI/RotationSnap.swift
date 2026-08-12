import Foundation

enum RotationSnap {
    static let intervalDegrees = 90.0
    static let toleranceDegrees = 4.0

    static func adjusted(_ rotation: Double) -> Double {
        guard rotation.isFinite else { return rotation }
        let nearestAxis = (rotation / intervalDegrees).rounded() * intervalDegrees
        guard abs(rotation - nearestAxis) <= toleranceDegrees else { return rotation }
        return nearestAxis == 0 ? 0 : nearestAxis
    }

    static func isAxisAligned(_ rotation: Double) -> Bool {
        guard rotation.isFinite else { return false }
        return rotation.truncatingRemainder(dividingBy: intervalDegrees) == 0
    }
}
