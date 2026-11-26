import Foundation

/// Cubic-bezier easing for a keyframe segment. Control points stay inside the unit square in X so
/// sampling remains monotonic in time.
struct KeyframeCurve: Codable, Sendable, Equatable {
    var control1X: Double
    var control1Y: Double
    var control2X: Double
    var control2Y: Double

    static let linear = KeyframeCurve(control1X: 0.25, control1Y: 0.25, control2X: 0.75, control2Y: 0.75)
    static let easeIn = KeyframeCurve(control1X: 0.42, control1Y: 0, control2X: 1, control2Y: 1)
    static let easeOut = KeyframeCurve(control1X: 0, control1Y: 0, control2X: 0.58, control2Y: 1)
    static let easeInOut = KeyframeCurve(control1X: 0.42, control1Y: 0, control2X: 0.58, control2Y: 1)

    init(control1X: Double, control1Y: Double, control2X: Double, control2Y: Double) {
        self.control1X = Self.clampX(control1X)
        self.control2X = Self.clampX(control2X)
        self.control1Y = Self.clampY(control1Y)
        self.control2Y = Self.clampY(control2Y)
    }

    /// Progress 0...1 for normalized time 0...1, solved on the X axis then evaluated on Y.
    func progress(at time: Double) -> Double {
        let t = min(1, max(0, time.isFinite ? time : 0))
        guard t > 0, t < 1 else { return t }
        var lower = 0.0, upper = 1.0
        for _ in 0..<24 {
            let mid = (lower + upper) / 2
            if Self.bezier(t: mid, p1: control1X, p2: control2X) < t { lower = mid } else { upper = mid }
        }
        let solved = (lower + upper) / 2
        return Self.bezier(t: solved, p1: control1Y, p2: control2Y)
    }

    private static func bezier(t: Double, p1: Double, p2: Double) -> Double {
        let oneMinus = 1 - t
        return 3 * oneMinus * oneMinus * t * p1 + 3 * oneMinus * t * t * p2 + t * t * t
    }

    private static func clampX(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private static func clampY(_ value: Double) -> Double { value.isFinite ? min(2, max(-1, value)) : 0 }
}

/// One editable lane per animated property, in the order the inspector shows them.
struct KeyframeLane: Sendable, Equatable {
    let property: String
    let frames: [Int]
}

enum KeyframeLanes {
    static let order = ["position", "scale", "rotation", "opacity", "volume", "crop"]

    /// Collapsed clips show one row; each animated property earns its own lane.
    static func lanes(for clip: Clip) -> [KeyframeLane] {
        var lanes: [KeyframeLane] = []
        if let track = clip.positionTrack, track.isActive { lanes.append(.init(property: "position", frames: track.keyframes.map(\.frame))) }
        if let track = clip.scaleTrack, track.isActive { lanes.append(.init(property: "scale", frames: track.keyframes.map(\.frame))) }
        if let track = clip.rotationTrack, track.isActive { lanes.append(.init(property: "rotation", frames: track.keyframes.map(\.frame))) }
        if let track = clip.opacityTrack, track.isActive { lanes.append(.init(property: "opacity", frames: track.keyframes.map(\.frame))) }
        if let track = clip.volumeTrack, track.isActive { lanes.append(.init(property: "volume", frames: track.keyframes.map(\.frame))) }
        if let track = clip.cropTrack, track.isActive { lanes.append(.init(property: "crop", frames: track.keyframes.map(\.frame))) }
        return lanes.sorted { a, b in
            let ai = order.firstIndex(of: a.property) ?? order.count
            let bi = order.firstIndex(of: b.property) ?? order.count
            return ai < bi
        }
    }
}

/// Copies keyframes between clips, applying only properties the target already animates.
enum KeyframeClipboard {
    struct Payload: Sendable, Equatable {
        var sourceClipId: String
        var position: KeyframeTrack<AnimPair>?
        var scale: KeyframeTrack<AnimPair>?
        var rotation: KeyframeTrack<Double>?
        var opacity: KeyframeTrack<Double>?
        var volume: KeyframeTrack<Double>?
        var crop: KeyframeTrack<Crop>?
        var isEmpty: Bool {
            position == nil && scale == nil && rotation == nil && opacity == nil && volume == nil && crop == nil
        }
    }

    static func copy(from clip: Clip) -> Payload {
        Payload(sourceClipId: clip.id, position: clip.positionTrack, scale: clip.scaleTrack,
                rotation: clip.rotationTrack, opacity: clip.opacityTrack,
                volume: clip.volumeTrack, crop: clip.cropTrack)
    }

    /// Paste never creates a property that the target does not already animate; mismatches no-op.
    @discardableResult
    static func paste(_ payload: Payload, into clip: inout Clip) -> Bool {
        var changed = false
        if clip.positionTrack?.isActive == true, let value = payload.position { clip.positionTrack = value; changed = true }
        if clip.scaleTrack?.isActive == true, let value = payload.scale { clip.scaleTrack = value; changed = true }
        if clip.rotationTrack?.isActive == true, let value = payload.rotation { clip.rotationTrack = value; changed = true }
        if clip.opacityTrack?.isActive == true, let value = payload.opacity { clip.opacityTrack = value; changed = true }
        if clip.volumeTrack?.isActive == true, let value = payload.volume { clip.volumeTrack = value; changed = true }
        if clip.cropTrack?.isActive == true, let value = payload.crop { clip.cropTrack = value; changed = true }
        return changed
    }
}
