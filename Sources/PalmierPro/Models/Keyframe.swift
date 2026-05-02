import Foundation

enum Interpolation: String, Codable, CaseIterable, Sendable {
    case linear, hold, smooth
}

struct Keyframe<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var frame: Int
    var value: Value
    var interpolationOut: Interpolation = .smooth
}

struct KeyframeTrack<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var keyframes: [Keyframe<Value>] = []

    var isActive: Bool { !keyframes.isEmpty }

    mutating func upsert(_ kf: Keyframe<Value>) {
        if let i = keyframes.firstIndex(where: { $0.frame == kf.frame }) {
            keyframes[i] = kf
        } else {
            let at = keyframes.firstIndex { $0.frame > kf.frame } ?? keyframes.endIndex
            keyframes.insert(kf, at: at)
        }
    }

    mutating func remove(at frame: Int) {
        keyframes.removeAll { $0.frame == frame }
    }

    mutating func move(from oldFrame: Int, to newFrame: Int) {
        guard let i = keyframes.firstIndex(where: { $0.frame == oldFrame }) else { return }
        var kf = keyframes.remove(at: i)
        kf.frame = newFrame
        upsert(kf)
    }
}

protocol KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Self, _ b: Self, t: Double) -> Self
}

extension Double: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Double, _ b: Double, t: Double) -> Double {
        a + (b - a) * t
    }
}

/// Two-component keyframe value used for position (x, y) and scale (width, height).
struct AnimPair: Codable, Sendable, Equatable, KeyframeInterpolatable {
    var a: Double
    var b: Double

    static func keyframeInterpolate(_ from: AnimPair, _ to: AnimPair, t: Double) -> AnimPair {
        AnimPair(
            a: Double.keyframeInterpolate(from.a, to.a, t: t),
            b: Double.keyframeInterpolate(from.b, to.b, t: t)
        )
    }
}

extension Crop: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Crop, _ b: Crop, t: Double) -> Crop {
        Crop(
            left: Double.keyframeInterpolate(a.left, b.left, t: t),
            top: Double.keyframeInterpolate(a.top, b.top, t: t),
            right: Double.keyframeInterpolate(a.right, b.right, t: t),
            bottom: Double.keyframeInterpolate(a.bottom, b.bottom, t: t)
        )
    }
}

/// Identifies which clip property an inspector lane / stamp button drives.
enum AnimatableProperty: String, CaseIterable, Sendable {
    case opacity, position, scale, crop

    var displayName: String {
        switch self {
        case .opacity:  "Opacity"
        case .position: "Position"
        case .scale:    "Scale"
        case .crop:     "Crop"
        }
    }
}

// MARK: - Clip keyframe helpers

extension Clip {
    func contains(timelineFrame frame: Int) -> Bool {
        frame >= startFrame && frame <= endFrame
    }

    /// Absolute timeline frame → clip-relative offset (used internally in track storage)
    private func toOffset(_ timelineFrame: Int) -> Int { timelineFrame - startFrame }
    /// Clip-relative offset → absolute timeline frame (used in public API)
    private func toAbs(_ offset: Int) -> Int { startFrame + offset }

    func keyframeFrames(for property: AnimatableProperty) -> [Int] {
        let offsets: [Int]
        switch property {
        case .opacity:  offsets = opacityTrack?.keyframes.map(\.frame) ?? []
        case .position: offsets = positionTrack?.keyframes.map(\.frame) ?? []
        case .scale:    offsets = scaleTrack?.keyframes.map(\.frame) ?? []
        case .crop:     offsets = cropTrack?.keyframes.map(\.frame) ?? []
        }
        return offsets.map(toAbs)
    }

    func interpolation(for property: AnimatableProperty, atFrame frame: Int) -> Interpolation? {
        let o = toOffset(frame)
        switch property {
        case .opacity:  return opacityTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .position: return positionTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .scale:    return scaleTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .crop:     return cropTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        }
    }

    /// Union of every animatable property's kf frames as absolute timeline frames.
    var allKeyframeFrames: [Int] {
        var s = Set<Int>()
        let absStart = startFrame
        for kf in opacityTrack?.keyframes ?? [] { s.insert(kf.frame + absStart) }
        for kf in positionTrack?.keyframes ?? [] { s.insert(kf.frame + absStart) }
        for kf in scaleTrack?.keyframes ?? [] { s.insert(kf.frame + absStart) }
        for kf in cropTrack?.keyframes ?? [] { s.insert(kf.frame + absStart) }
        return s.sorted()
    }

    mutating func upsertKeyframe<V>(
        in keyPath: WritableKeyPath<Clip, KeyframeTrack<V>?>,
        frame: Int,
        value: V
    ) {
        var t = self[keyPath: keyPath] ?? KeyframeTrack<V>()
        // `frame` is an absolute timeline frame; storage is converted to clip-relative via `toOffset`
        t.upsert(Keyframe(frame: toOffset(frame), value: value))
        self[keyPath: keyPath] = t
    }

    mutating func removeKeyframe(for property: AnimatableProperty, at frame: Int) {
        let o = toOffset(frame)
        switch property {
        case .opacity:
            opacityTrack?.remove(at: o)
            if opacityTrack?.keyframes.isEmpty == true { opacityTrack = nil }
        case .position:
            positionTrack?.remove(at: o)
            if positionTrack?.keyframes.isEmpty == true { positionTrack = nil }
        case .scale:
            scaleTrack?.remove(at: o)
            if scaleTrack?.keyframes.isEmpty == true { scaleTrack = nil }
        case .crop:
            cropTrack?.remove(at: o)
            if cropTrack?.keyframes.isEmpty == true { cropTrack = nil }
        }
    }

    mutating func clearKeyframes(for property: AnimatableProperty) {
        switch property {
        case .opacity:  opacityTrack = nil
        case .position: positionTrack = nil
        case .scale:    scaleTrack = nil
        case .crop:     cropTrack = nil
        }
    }

    mutating func setInterpolation(for property: AnimatableProperty, atFrame frame: Int, _ interpolation: Interpolation) {
        let o = toOffset(frame)
        switch property {
        case .opacity:
            if let i = opacityTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                opacityTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .position:
            if let i = positionTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                positionTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .scale:
            if let i = scaleTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                scaleTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .crop:
            if let i = cropTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                cropTrack?.keyframes[i].interpolationOut = interpolation
            }
        }
    }

    mutating func moveKeyframe(for property: AnimatableProperty, from: Int, to: Int) {
        let fromO = toOffset(from), toO = toOffset(to)
        switch property {
        case .opacity:  opacityTrack?.move(from: fromO, to: toO)
        case .position: positionTrack?.move(from: fromO, to: toO)
        case .scale:    scaleTrack?.move(from: fromO, to: toO)
        case .crop:     cropTrack?.move(from: fromO, to: toO)
        }
    }
}

extension KeyframeTrack where Value: KeyframeInterpolatable {
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
        case .smooth: return Value.keyframeInterpolate(a.value, b.value, t: raw * raw * (3 - 2 * raw))
        }
    }
}
