import AppKit

extension EditorViewModel {

    // MARK: - Read

    func keyframeFrames(clipId: String, property: AnimatableProperty) -> [Int] {
        clipFor(id: clipId)?.keyframeFrames(for: property) ?? []
    }

    func hasKeyframe(clipId: String, property: AnimatableProperty, at frame: Int) -> Bool {
        keyframeFrames(clipId: clipId, property: property).contains(frame)
    }

    func previousKeyframeFrame(clipId: String, property: AnimatableProperty, before frame: Int) -> Int? {
        keyframeFrames(clipId: clipId, property: property).filter { $0 < frame }.max()
    }

    func nextKeyframeFrame(clipId: String, property: AnimatableProperty, after frame: Int) -> Int? {
        keyframeFrames(clipId: clipId, property: property).filter { $0 > frame }.min()
    }

    func interpolation(clipId: String, property: AnimatableProperty, atFrame frame: Int) -> Interpolation? {
        clipFor(id: clipId)?.interpolation(for: property, atFrame: frame)
    }

    // MARK: - Stamp / remove / clear

    func stampKeyframe(clipId: String, property: AnimatableProperty, frame: Int? = nil) {
        guard let clip = clipFor(id: clipId) else { return }
        let f = frame ?? currentFrame
        guard clip.contains(timelineFrame: f) else { return }
        commitClipProperty(clipId: clipId, actionName: "Add Keyframe") { clip in
            switch property {
            case .opacity:
                clip.upsertKeyframe(in: \.opacityTrack, frame: f, value: clip.rawOpacityAt(frame: f))
            case .position:
                let tl = clip.topLeftAt(frame: f)
                clip.upsertKeyframe(in: \.positionTrack, frame: f, value: AnimPair(a: tl.x, b: tl.y))
            case .scale:
                let sz = clip.sizeAt(frame: f)
                clip.upsertKeyframe(in: \.scaleTrack, frame: f, value: AnimPair(a: sz.width, b: sz.height))
            case .rotation:
                clip.upsertKeyframe(in: \.rotationTrack, frame: f, value: clip.rotationAt(frame: f))
            case .crop:
                clip.upsertKeyframe(in: \.cropTrack, frame: f, value: clip.cropAt(frame: f))
            case .volume:
                let currentDb = clip.volumeTrack?.sample(at: f - clip.startFrame, fallback: 0) ?? 0
                clip.upsertKeyframe(in: \.volumeTrack, frame: f, value: currentDb)
            }
        }
    }

    func removeKeyframe(clipId: String, property: AnimatableProperty, at frame: Int) {
        commitClipProperty(clipId: clipId, actionName: "Delete Keyframe") { $0.removeKeyframe(for: property, at: frame) }
    }

    func setInterpolation(clipId: String, property: AnimatableProperty, frame: Int, interpolation: Interpolation) {
        commitClipProperty(clipId: clipId, actionName: "Change Interpolation") { $0.setInterpolation(for: property, atFrame: frame, interpolation) }
    }

    // MARK: - Drag-to-move keyframe

    /// Live move during a drag — pair with `commitMoveKeyframe` on release for a single undo entry.
    func applyMoveKeyframe(clipId: String, property: AnimatableProperty, fromFrame: Int, toFrame: Int) {
        applyClipProperty(clipId: clipId) { $0.moveKeyframe(for: property, from: fromFrame, to: toFrame) }
    }

    /// Closes the drag started by `applyMoveKeyframe` calls.
    func commitMoveKeyframe(clipId: String) {
        commitClipProperty(clipId: clipId, actionName: "Move Keyframe") { _ in /* applies already moved the kf */ }
    }

    // MARK: - Animation-aware property writes

    func applyOpacity(clipId: String, value: Double) {
        applyClipProperty(clipId: clipId) { self.writeOpacity(into: &$0, value: value) }
    }

    func commitOpacity(clipId: String, value: Double) {
        commitClipProperty(clipId: clipId, actionName: "Change Opacity") { self.writeOpacity(into: &$0, value: value) }
    }

    private func writeOpacity(into clip: inout Clip, value: Double) {
        let frame = activeFrame
        if clip.opacityTrack?.isActive == true {
            clip.upsertKeyframe(in: \.opacityTrack, frame: frame, value: value)
        } else {
            clip.opacity = value
        }
    }

    func applyRotation(clipId: String, valueDeg: Double) {
        applyClipProperty(clipId: clipId) { self.writeRotation(into: &$0, valueDeg: valueDeg) }
    }

    func commitRotation(clipId: String, valueDeg: Double) {
        commitClipProperty(clipId: clipId, actionName: "Change Rotation") { self.writeRotation(into: &$0, valueDeg: valueDeg) }
    }

    private func writeRotation(into clip: inout Clip, valueDeg: Double) {
        if clip.rotationTrack?.isActive == true {
            clip.upsertKeyframe(in: \.rotationTrack, frame: activeFrame, value: valueDeg)
        } else {
            clip.transform.rotation = valueDeg
        }
    }

    func applyVolume(clipId: String, valueDb: Double) {
        applyClipProperty(clipId: clipId) { self.writeVolume(into: &$0, valueDb: valueDb) }
    }

    func commitVolume(clipId: String, valueDb: Double) {
        commitClipProperty(clipId: clipId, actionName: "Change Volume") { self.writeVolume(into: &$0, valueDb: valueDb) }
    }

    private func writeVolume(into clip: inout Clip, valueDb: Double) {
        if clip.liveVolumeKfDb(at: activeFrame) != nil {
            clip.upsertKeyframe(in: \.volumeTrack, frame: activeFrame, value: valueDb)
        } else {
            clip.volume = VolumeScale.linearFromDb(valueDb)
        }
    }

    // MARK: - Fades

    func applyFade(clipId: String, edge: FadeEdge, frames: Int) {
        applyClipProperty(clipId: clipId) { $0.setFade(edge, frames: frames) }
    }

    func commitFade(clipId: String, edge: FadeEdge, frames: Int) {
        commitClipProperty(clipId: clipId, actionName: edge == .left ? "Change Fade In" : "Change Fade Out") {
            $0.setFade(edge, frames: frames)
        }
    }

    func setFadeInterpolation(clipId: String, edge: FadeEdge, interpolation: Interpolation) {
        commitClipProperty(clipId: clipId, actionName: "Change Fade Interpolation") {
            $0.setFadeInterpolation(edge, interpolation)
        }
    }

    func applyPositions(clipIds: [String], setX: Double?, setY: Double?) {
        applyClipProperties(clipIds: clipIds) { self.writePosition(into: &$0, setX: setX, setY: setY) }
    }

    func commitPositions(clipIds: [String], setX: Double?, setY: Double?) {
        commitClipProperties(clipIds: clipIds, actionName: "Change Position") {
            self.writePosition(into: &$0, setX: setX, setY: setY)
        }
    }

    private func writePosition(into clip: inout Clip, setX: Double?, setY: Double?) {
        let frame = activeFrame
        let tl = clip.topLeftAt(frame: frame)
        let newX = setX ?? tl.x
        let newY = setY ?? tl.y
        let sz = clip.sizeAt(frame: frame)
        if clip.positionTrack?.isActive == true {
            clip.upsertKeyframe(in: \.positionTrack, frame: frame, value: AnimPair(a: newX, b: newY))
        } else {
            clip.transform.centerX = newX + sz.width / 2
            clip.transform.centerY = newY + sz.height / 2
        }
    }

    func applyScale(clipId: String, newScale: Double) {
        applyClipProperty(clipId: clipId) { self.writeScale(into: &$0, newScale: newScale) }
    }

    func commitScale(clipId: String, newScale: Double) {
        commitClipProperty(clipId: clipId, actionName: "Change Scale") {
            self.writeScale(into: &$0, newScale: newScale)
        }
    }

    private func writeScale(into clip: inout Clip, newScale: Double) {
        let aspect = mediaCanvasAspect(for: clip) ?? 1.0
        let w = newScale
        let h = newScale / aspect
        if clip.scaleTrack?.isActive == true {
            clip.upsertKeyframe(in: \.scaleTrack, frame: activeFrame, value: AnimPair(a: w, b: h))
        } else {
            clip.transform.width = w
            clip.transform.height = h
        }
    }

    func applyTransform(clipId: String, newTransform: Transform) {
        applyClipProperty(clipId: clipId) { self.writeTransform(into: &$0, newTransform: newTransform) }
    }

    func commitTransform(clipId: String, newTransform: Transform, actionName: String = "Change Transform") {
        commitClipProperty(clipId: clipId, actionName: actionName) {
            self.writeTransform(into: &$0, newTransform: newTransform)
        }
    }

    private func writeTransform(into clip: inout Clip, newTransform: Transform) {
        let frame = activeFrame
        if clip.positionTrack?.isActive == true {
            let tl = newTransform.topLeft
            clip.upsertKeyframe(in: \.positionTrack, frame: frame, value: AnimPair(a: tl.x, b: tl.y))
        } else {
            clip.transform.centerX = newTransform.centerX
            clip.transform.centerY = newTransform.centerY
        }
        if clip.scaleTrack?.isActive == true {
            clip.upsertKeyframe(in: \.scaleTrack, frame: frame, value: AnimPair(a: newTransform.width, b: newTransform.height))
        } else {
            clip.transform.width = newTransform.width
            clip.transform.height = newTransform.height
        }
        if clip.rotationTrack?.isActive == true {
            clip.upsertKeyframe(in: \.rotationTrack, frame: frame, value: newTransform.rotation)
        } else {
            clip.transform.rotation = newTransform.rotation
        }
    }

    func applyCrop(clipId: String, newCrop: Crop) {
        applyClipProperty(clipId: clipId) { self.writeCrop(into: &$0, newCrop: newCrop) }
    }

    func commitCrop(clipId: String, newCrop: Crop) {
        commitClipProperty(clipId: clipId, actionName: "Change Crop") {
            self.writeCrop(into: &$0, newCrop: newCrop)
        }
    }

    private func writeCrop(into clip: inout Clip, newCrop: Crop) {
        if clip.cropTrack?.isActive == true {
            clip.upsertKeyframe(in: \.cropTrack, frame: activeFrame, value: newCrop)
        } else {
            clip.crop = newCrop
        }
    }

    // MARK: - Volume keyframe 2D drag (rubber band)

    /// Pair with `commitMoveVolumeKeyframe` on release for a single undo entry.
    func applyMoveVolumeKeyframe(clipId: String, fromFrame: Int, toFrame: Int, newDb: Double) {
        applyClipProperty(clipId: clipId) { clip in
            let fromOffset = fromFrame - clip.startFrame
            let toOffset = toFrame - clip.startFrame
            guard var track = clip.volumeTrack,
                  let idx = track.keyframes.firstIndex(where: { $0.frame == fromOffset }) else { return }
            let interp = track.keyframes[idx].interpolationOut
            track.keyframes.remove(at: idx)
            track.upsert(Keyframe(frame: toOffset, value: newDb, interpolationOut: interp))
            clip.volumeTrack = track
        }
    }

    func commitMoveVolumeKeyframe(clipId: String) {
        commitClipProperty(clipId: clipId, actionName: "Move Keyframe") { _ in /* applied during drag */ }
    }
}
