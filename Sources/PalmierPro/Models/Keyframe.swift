import Foundation

// Generic keyframe machinery (Interpolation, Keyframe, KeyframeTrack, AnimPair,
// smoothstep, KeyframeInterpolatable, AnimatableProperty) lives in PalmierCore
// and is re-exported. The Crop: KeyframeInterpolatable conformance also moved
// to core once Crop moved. Only the Clip keyframe helpers that drive app-side
// inspector behavior remain here.

// MARK: - Clip keyframe helpers

extension Clip {
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
        case .rotation: offsets = rotationTrack?.keyframes.map(\.frame) ?? []
        case .crop:     offsets = cropTrack?.keyframes.map(\.frame) ?? []
        case .volume:   offsets = volumeTrack?.keyframes.map(\.frame) ?? []
        }
        return offsets.map(toAbs)
    }

    func interpolation(for property: AnimatableProperty, atFrame frame: Int) -> Interpolation? {
        let o = toOffset(frame)
        switch property {
        case .opacity:  return opacityTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .position: return positionTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .scale:    return scaleTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .rotation: return rotationTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .crop:     return cropTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .volume:   return volumeTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        }
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
        case .rotation:
            rotationTrack?.remove(at: o)
            if rotationTrack?.keyframes.isEmpty == true { rotationTrack = nil }
        case .crop:
            cropTrack?.remove(at: o)
            if cropTrack?.keyframes.isEmpty == true { cropTrack = nil }
        case .volume:
            volumeTrack?.remove(at: o)
            if volumeTrack?.keyframes.isEmpty == true { volumeTrack = nil }
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
        case .rotation:
            if let i = rotationTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                rotationTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .crop:
            if let i = cropTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                cropTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .volume:
            if let i = volumeTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                volumeTrack?.keyframes[i].interpolationOut = interpolation
            }
        }
    }

    mutating func moveKeyframe(for property: AnimatableProperty, from: Int, to: Int) {
        let fromO = toOffset(from), toO = toOffset(to)
        switch property {
        case .opacity:  opacityTrack?.move(from: fromO, to: toO)
        case .position: positionTrack?.move(from: fromO, to: toO)
        case .scale:    scaleTrack?.move(from: fromO, to: toO)
        case .rotation: rotationTrack?.move(from: fromO, to: toO)
        case .crop:     cropTrack?.move(from: fromO, to: toO)
        case .volume:   volumeTrack?.move(from: fromO, to: toO)
        }
    }
}
