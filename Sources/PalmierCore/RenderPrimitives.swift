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
    /// CGAffineTransform stores `(a,b,c,d,tx,ty)` but the effective 3×3 matrix
    /// layout is `[a c tx; b d ty; 0 0 1]` (i.e. `b` and `c` are swapped vs the
    /// stored-tuple reading), and `t1.concatenating(t2)` is the product
    /// `T_other * T_self` — apply `self` to a point first, then `other`.
    /// Verified empirically against CGAffineTransform on macOS across diagonal,
    /// rotation, and flipY cases; doc-only derivation got the layout/order wrong
    /// repeatedly because the stored-tuple order doesn't match the matrix order.
    public func concatenating(_ other: Mat3) -> Mat3 {
        Mat3(
            a: other.a * a + other.c * b,
            b: other.b * a + other.d * b,
            c: other.a * c + other.c * d,
            d: other.b * c + other.d * d,
            tx: other.a * tx + other.c * ty + other.tx,
            ty: other.b * tx + other.d * ty + other.ty
        )
    }

    public func inverted() -> Mat3 {
        let det = a * d - b * c
        guard det != 0 else { return .identity }
        let inv = 1 / det
        // Layout [a c tx; b d ty]: inverse linear is [d -c; -b a]/det and the
        // inverse translation is (c*ty - d*tx, b*tx - a*ty)/det.
        return Mat3(
            a: d * inv,
            b: -b * inv,
            c: -c * inv,
            d: a * inv,
            tx: (c * ty - d * tx) * inv,
            ty: (b * tx - a * ty) * inv
        )
    }
}
