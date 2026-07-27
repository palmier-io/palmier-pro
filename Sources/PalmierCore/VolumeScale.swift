import Foundation

/// Linear ⇄ decibel conversion for clip volume. Pure math, no platform deps.
public enum VolumeScale {
    public static let floorDb: Double = -60
    public static let ceilingDb: Double = 15

    public static func dbFromLinear(_ linear: Double) -> Double {
        guard linear > 0 else { return floorDb }
        return min(ceilingDb, max(floorDb, 20 * log10(linear)))
    }

    public static func linearFromDb(_ db: Double) -> Double {
        guard db > floorDb else { return 0 }
        return pow(10, min(db, ceilingDb) / 20)
    }
}
