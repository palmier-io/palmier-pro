import Foundation

/// Identifier of a composition track that supplies decoded source frames.
/// Abstracted from AVFoundation's `CMPersistentTrackID` so the render contract
/// stays portable: macOS bridges `TrackID(rawValue:) <-> CMPersistentTrackID`,
/// Windows uses the raw value to key its Media Foundation decoder slots.
public struct TrackID: Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
}

/// Portable 2D size in pixels. Bridged to `CGSize` on macOS and
/// `D2D1_SIZE_F` / `SIZE` on Windows at platform boundaries.
public struct Size2D: Hashable, Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size2D(width: 0, height: 0)
}

/// 2×3 affine transform in row-major order: `[a, b, c, d, tx, ty]`, mapping
/// `(x, y) -> (a*x + c*y + tx, b*x + d*y + ty)`. Matches `CGAffineTransform`'s
/// layout and `D2D1_MATRIX_3X2_F`'s `_11,_12,_21,_22,_31,_32` layout, so it
/// bridges with zero math at both platform boundaries.
public struct Mat3: Hashable, Sendable, Equatable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Mat3()

    /// Compose transforms matching `CGAffineTransform.concatenating` semantics.
    /// `t1.concatenating(t2)` is the matrix product `T1 * T2` with layout
    /// `[a b tx; c d ty; 0 0 1]` (Apple: a=[1,1], b=[1,2], c=[2,1], d=[2,2]) —
    /// i.e. apply `t2` to a point first, then `t1`. Verified empirically against
    /// CGAffineTransform on macOS across diagonal, rotation, and flipY cases
    /// (see Mat3CGAffineTransformParityTests); the earlier doc-only derivations
    /// got the matrix layout / multiplication order wrong twice.
    public func concatenating(_ other: Mat3) -> Mat3 {
        Mat3(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public func inverted() -> Mat3 {
        let det = a * d - b * c
        guard det != 0 else { return .identity }
        let inv = 1 / det
        let newA = d * inv
        let newB = -b * inv
        let newC = -c * inv
        let newD = a * inv
        // Layout [a b tx; c d ty]: inverse translation is -(linear * translation).
        return Mat3(
            a: newA, b: newB, c: newC, d: newD,
            tx: -(newA * tx + newB * ty),
            ty: -(newC * tx + newD * ty)
        )
    }
}
