import AppKit

extension EditorViewModel {

    // MARK: - Read

    func keyframeFrames(clipId: String, property: AnimatableProperty) -> [Int] {
        clipFor(id: clipId)?.keyframeFrames(for: property) ?? []
    }

    func hasKeyframe(clipId: String, property: AnimatableProperty, at frame: Int) -> Bool {
        keyframeFrames(clipId: clipId, property: property).contains(frame)
    }

    func interpolation(clipId: String, property: AnimatableProperty, atFrame frame: Int) -> Interpolation? {
        clipFor(id: clipId)?.interpolation(for: property, atFrame: frame)
    }

    // MARK: - Stamp / remove / clear

    func stampKeyframe(clipId: String, property: AnimatableProperty, frame: Int? = nil) {
        guard let clip = clipFor(id: clipId) else { return }
        let f = frame ?? currentFrame
        guard clip.contains(timelineFrame: f) else { return }
        commitClipProperty(clipId: clipId) { clip in
            switch property {
            case .opacity:
                clip.upsertKeyframe(in: \.opacityTrack, frame: f, value: clip.opacityAt(frame: f))
            case .position:
                let tl = clip.topLeftAt(frame: f)
                clip.upsertKeyframe(in: \.positionTrack, frame: f, value: AnimPair(a: tl.x, b: tl.y))
            case .scale:
                let sz = clip.sizeAt(frame: f)
                clip.upsertKeyframe(in: \.scaleTrack, frame: f, value: AnimPair(a: sz.width, b: sz.height))
            case .crop:
                clip.upsertKeyframe(in: \.cropTrack, frame: f, value: clip.cropAt(frame: f))
            }
        }
        undoManager?.setActionName("Add Keyframe")
    }

    func removeKeyframe(clipId: String, property: AnimatableProperty, at frame: Int) {
        commitClipProperty(clipId: clipId) { $0.removeKeyframe(for: property, at: frame) }
        undoManager?.setActionName("Delete Keyframe")
    }

    func clearAnimation(clipId: String, property: AnimatableProperty) {
        commitClipProperty(clipId: clipId) { $0.clearKeyframes(for: property) }
        undoManager?.setActionName("Clear Animation")
    }

    func setInterpolation(clipId: String, property: AnimatableProperty, frame: Int, interpolation: Interpolation) {
        commitClipProperty(clipId: clipId) { $0.setInterpolation(for: property, atFrame: frame, interpolation) }
        undoManager?.setActionName("Change Interpolation")
    }

    // MARK: - Drag-to-move keyframe

    /// Live move during a drag — pair with `commitMoveKeyframe` on release for a single undo entry.
    func applyMoveKeyframe(clipId: String, property: AnimatableProperty, fromFrame: Int, toFrame: Int) {
        applyClipProperty(clipId: clipId) { $0.moveKeyframe(for: property, from: fromFrame, to: toFrame) }
    }

    /// Closes the drag started by `applyMoveKeyframe` calls.
    func commitMoveKeyframe(clipId: String) {
        commitClipProperty(clipId: clipId) { _ in /* applies already moved the kf */ }
        undoManager?.setActionName("Move Keyframe")
    }

    // MARK: - Animation-aware property writes

    func applyOpacity(clipId: String, value: Double) {
        applyClipProperty(clipId: clipId) { self.writeOpacity(into: &$0, value: value) }
    }

    func commitOpacity(clipId: String, value: Double) {
        commitClipProperty(clipId: clipId) { self.writeOpacity(into: &$0, value: value) }
        undoManager?.setActionName("Change Opacity")
    }

    private func writeOpacity(into clip: inout Clip, value: Double) {
        if clip.opacityTrack?.isActive == true {
            clip.upsertKeyframe(in: \.opacityTrack, frame: currentFrame, value: value)
        } else {
            clip.opacity = value
        }
    }

    func applyPosition(clipId: String, setX: Double?, setY: Double?) {
        applyClipProperty(clipId: clipId) { self.writePosition(into: &$0, setX: setX, setY: setY) }
    }

    func commitPosition(clipId: String, setX: Double?, setY: Double?) {
        commitClipProperty(clipId: clipId) { self.writePosition(into: &$0, setX: setX, setY: setY) }
        undoManager?.setActionName("Change Position")
    }

    private func writePosition(into clip: inout Clip, setX: Double?, setY: Double?) {
        let tl = clip.topLeftAt(frame: currentFrame)
        let newX = setX ?? tl.x
        let newY = setY ?? tl.y
        if clip.positionTrack?.isActive == true {
            clip.upsertKeyframe(in: \.positionTrack, frame: currentFrame, value: AnimPair(a: newX, b: newY))
        } else {
            clip.transform = Transform(topLeft: (newX, newY), width: clip.transform.width, height: clip.transform.height)
        }
    }

    func applyScale(clipId: String, newScale: Double) {
        applyClipProperty(clipId: clipId) { self.writeScale(into: &$0, newScale: newScale) }
    }

    func commitScale(clipId: String, newScale: Double) {
        commitClipProperty(clipId: clipId) { self.writeScale(into: &$0, newScale: newScale) }
        undoManager?.setActionName("Change Scale")
    }

    private func writeScale(into clip: inout Clip, newScale: Double) {
        let aspect = mediaCanvasAspect(for: clip) ?? 1.0
        let w = newScale
        let h = newScale / aspect
        if clip.scaleTrack?.isActive == true {
            clip.upsertKeyframe(in: \.scaleTrack, frame: currentFrame, value: AnimPair(a: w, b: h))
        } else {
            clip.transform = Transform(center: clip.transform.center, width: w, height: h)
        }
    }

    func applyTransform(clipId: String, newTransform: Transform) {
        applyClipProperty(clipId: clipId) { self.writeTransform(into: &$0, newTransform: newTransform) }
    }

    func commitTransform(clipId: String, newTransform: Transform, actionName: String = "Change Transform") {
        commitClipProperty(clipId: clipId) { self.writeTransform(into: &$0, newTransform: newTransform) }
        undoManager?.setActionName(actionName)
    }

    private func writeTransform(into clip: inout Clip, newTransform: Transform) {
        let posActive = clip.positionTrack?.isActive == true
        let scaleActive = clip.scaleTrack?.isActive == true

        if posActive {
            let tl = newTransform.topLeft
            clip.upsertKeyframe(in: \.positionTrack, frame: currentFrame, value: AnimPair(a: tl.x, b: tl.y))
        }
        if scaleActive {
            clip.upsertKeyframe(in: \.scaleTrack, frame: currentFrame, value: AnimPair(a: newTransform.width, b: newTransform.height))
        }
        if !posActive && !scaleActive {
            clip.transform = newTransform
        }
    }

    func applyCrop(clipId: String, newCrop: Crop) {
        applyClipProperty(clipId: clipId) { self.writeCrop(into: &$0, newCrop: newCrop) }
    }

    func commitCrop(clipId: String, newCrop: Crop) {
        commitClipProperty(clipId: clipId) { self.writeCrop(into: &$0, newCrop: newCrop) }
        undoManager?.setActionName("Change Crop")
    }

    private func writeCrop(into clip: inout Clip, newCrop: Crop) {
        if clip.cropTrack?.isActive == true {
            clip.upsertKeyframe(in: \.cropTrack, frame: currentFrame, value: newCrop)
        } else {
            clip.crop = newCrop
        }
    }
}
