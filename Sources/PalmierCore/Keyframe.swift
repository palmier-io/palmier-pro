import Foundation

public enum Interpolation: String, Codable, CaseIterable, Sendable {
    case linear, hold, smooth
}

public struct Keyframe<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var frame: Int
    public var value: Value
    public var interpolationOut: Interpolation = .smooth

    public init(frame: Int, value: Value, interpolationOut: Interpolation = .smooth) {
        self.frame = frame
        self.value = value
        self.interpolationOut = interpolationOut
    }
}

public struct KeyframeTrack<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var keyframes: [Keyframe<Value>] = []

    public init(keyframes: [Keyframe<Value>] = []) {
        self.keyframes = keyframes
    }

    public var isActive: Bool { !keyframes.isEmpty }

    public mutating func upsert(_ kf: Keyframe<Value>) {
        if let i = keyframes.firstIndex(where: { $0.frame == kf.frame }) {
            keyframes[i] = kf
        } else {
            let at = keyframes.firstIndex { $0.frame > kf.frame } ?? keyframes.endIndex
            keyframes.insert(kf, at: at)
        }
    }

    public mutating func remove(at frame: Int) {
        keyframes.removeAll { $0.frame == frame }
    }

    public mutating func move(from oldFrame: Int, to newFrame: Int) {
        guard let i = keyframes.firstIndex(where: { $0.frame == oldFrame }) else { return }
        if newFrame != oldFrame, keyframes.contains(where: { $0.frame == newFrame }) { return }
        var kf = keyframes.remove(at: i)
        kf.frame = newFrame
        upsert(kf)
    }
}

public extension KeyframeTrack where Value: KeyframeInterpolatable {
    func rebased(by offset: Int, fallback: Value) -> KeyframeTrack? {
        guard isActive else { return nil }
        let boundary = sample(at: offset, fallback: fallback)
        var kfs = keyframes
            .filter { $0.frame >= offset }
            .map { Keyframe(frame: $0.frame - offset, value: $0.value, interpolationOut: $0.interpolationOut) }
        if kfs.first?.frame != 0 {
            let interp = keyframes.last { $0.frame < offset }?.interpolationOut ?? .smooth
            kfs.insert(Keyframe(frame: 0, value: boundary, interpolationOut: interp), at: 0)
        }
        return kfs.isEmpty ? nil : KeyframeTrack(keyframes: kfs)
    }

    func sample(at frame: Int, fallback: Value) -> Value {
        guard !keyframes.isEmpty else { return fallback }
        if keyframes.count == 1 { return keyframes[0].value }
        if frame <= keyframes[0].frame { return keyframes[0].value }
        if frame >= keyframes.last!.frame { return keyframes.last!.value }

        guard let bIdx = keyframes.firstIndex(where: { $0.frame > frame }) else {
            return keyframes.last!.value
        }
        let a = keyframes[bIdx - 1]
        let b = keyframes[bIdx]
        let raw = Double(frame - a.frame) / Double(b.frame - a.frame)
        switch a.interpolationOut {
        case .hold:   return a.value
        case .linear: return Value.keyframeInterpolate(a.value, b.value, t: raw)
        case .smooth: return Value.keyframeInterpolate(a.value, b.value, t: smoothstep(raw))
        }
    }
}

@inlinable public func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

public protocol KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Self, _ b: Self, t: Double) -> Self
}

extension Double: KeyframeInterpolatable {
    public static func keyframeInterpolate(_ a: Double, _ b: Double, t: Double) -> Double {
        a + (b - a) * t
    }
}

/// Two-component keyframe value used for position (x, y) and scale (width, height).
public struct AnimPair: Codable, Sendable, Equatable, KeyframeInterpolatable {
    public var a: Double
    public var b: Double

    public init(a: Double, b: Double) {
        self.a = a
        self.b = b
    }

    public static func keyframeInterpolate(_ from: AnimPair, _ to: AnimPair, t: Double) -> AnimPair {
        AnimPair(
            a: Double.keyframeInterpolate(from.a, to.a, t: t),
            b: Double.keyframeInterpolate(from.b, to.b, t: t)
        )
    }
}

/// Identifies which clip property an inspector lane / stamp button drives.
public enum AnimatableProperty: String, CaseIterable, Sendable {
    case opacity, position, scale, rotation, crop, volume

    public var displayName: String {
        switch self {
        case .opacity:  "Opacity"
        case .position: "Position"
        case .scale:    "Scale"
        case .rotation: "Rotation"
        case .crop:     "Crop"
        case .volume:   "Volume"
        }
    }
}
