import AppKit

struct KeyframeLaneNavigationTarget: Equatable {
    let clipId: String
    let frame: Int
}

struct KeyframeNavigationCacheKey: Hashable {
    let trackId: String
    let property: AnimatableProperty
}

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

    func keyframeLaneTarget(
        trackId: String,
        property: AnimatableProperty,
        at frame: Int? = nil
    ) -> Clip? {
        let targetFrame = frame ?? activeFrame
        guard let track = timeline.tracks.first(where: { $0.id == trackId }) else { return nil }
        return track.clips.first {
            $0.contains(timelineFrame: targetFrame) && $0.supportsKeyframes(for: property)
        }
    }

    func keyframeLaneNavigationTargets(
        trackId: String,
        property: AnimatableProperty,
        around frame: Int
    ) -> (previous: KeyframeLaneNavigationTarget?, next: KeyframeLaneNavigationTarget?) {
        let targets = cachedKeyframeLaneNavigationTargets(
            trackId: trackId,
            property: property
        )
        let previousIndex = firstNavigationIndex(
            in: targets,
            frame: frame,
            strictlyAfter: false
        ) - 1
        let nextIndex = firstNavigationIndex(
            in: targets,
            frame: frame,
            strictlyAfter: true
        )
        return (
            targets.indices.contains(previousIndex) ? targets[previousIndex] : nil,
            targets.indices.contains(nextIndex) ? targets[nextIndex] : nil
        )
    }

    private func cachedKeyframeLaneNavigationTargets(
        trackId: String,
        property: AnimatableProperty
    ) -> [KeyframeLaneNavigationTarget] {
        if keyframeNavigationCacheTimelineId != activeTimelineId
            || keyframeNavigationCacheRevision != timelineRenderRevision {
            keyframeNavigationCacheTimelineId = activeTimelineId
            keyframeNavigationCacheRevision = timelineRenderRevision
            keyframeNavigationCache.removeAll(keepingCapacity: true)
        }
        let key = KeyframeNavigationCacheKey(trackId: trackId, property: property)
        if let cached = keyframeNavigationCache[key] {
            return cached
        }
        guard let track = timeline.tracks.first(where: { $0.id == trackId }) else {
            return []
        }
        var targets: [KeyframeLaneNavigationTarget] = []
        for clip in track.clips where clip.supportsKeyframes(for: property) {
            targets += clip.keyframeFrames(for: property).map {
                KeyframeLaneNavigationTarget(clipId: clip.id, frame: $0)
            }
        }
        targets.sort {
            $0.frame == $1.frame
                ? $0.clipId < $1.clipId
                : $0.frame < $1.frame
        }
        keyframeNavigationCache[key] = targets
        return targets
    }

    private func firstNavigationIndex(
        in targets: [KeyframeLaneNavigationTarget],
        frame: Int,
        strictlyAfter: Bool
    ) -> Int {
        var lower = 0
        var upper = targets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let advances = strictlyAfter
                ? targets[middle].frame <= frame
                : targets[middle].frame < frame
            if advances {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    func toggleKeyframe(clipId: String, property: AnimatableProperty, at frame: Int) {
        if hasKeyframe(clipId: clipId, property: property, at: frame) {
            removeKeyframe(clipId: clipId, property: property, at: frame)
        } else {
            stampKeyframe(clipId: clipId, property: property, frame: frame)
        }
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
        applyClipProperty(clipId: clipId, seekMode: .interactiveScrub) {
            $0.moveKeyframe(for: property, from: fromFrame, to: toFrame)
        }
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
            guard clip.contains(timelineFrame: frame) else { return }
            clip.upsertKeyframe(in: \.opacityTrack, frame: frame, value: value)
        } else {
            clip.opacity = value
        }
    }

    func applyRotation(clipIds: [String], valueDeg: Double) {
        applyClipProperties(clipIds: clipIds) { self.writeRotation(into: &$0, valueDeg: valueDeg) }
    }

    func commitRotation(clipIds: [String], valueDeg: Double) {
        commitClipProperties(clipIds: clipIds, actionName: "Change Rotation") {
            self.writeRotation(into: &$0, valueDeg: valueDeg)
        }
    }

    private func writeRotation(into clip: inout Clip, valueDeg: Double) {
        if clip.rotationTrack?.isActive == true {
            guard clip.contains(timelineFrame: activeFrame) else { return }
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
        if clip.volumeTrack?.isActive == true {
            guard clip.contains(timelineFrame: activeFrame) else { return }
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
            guard clip.contains(timelineFrame: frame) else { return }
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

    func applyTextSize(clipId: String, value: Double) {
        applyClipProperty(clipId: clipId) { self.writeTextSize(into: &$0, value: value) }
    }

    func commitTextSize(clipId: String, value: Double) {
        commitClipProperty(clipId: clipId, actionName: "Change Text Size") {
            self.writeTextSize(into: &$0, value: value)
        }
    }

    func resetTextSize(clipIds: [String], defaultSize: Double) {
        commitClipProperties(clipIds: clipIds, actionName: "Reset Text Size") { clip in
            guard clip.mediaType == .text else { return }
            clip.scaleTrack = nil
            self.writeTextSize(into: &clip, value: defaultSize)
        }
    }

    private func writeTextSize(into clip: inout Clip, value: Double) {
        guard clip.mediaType == .text, value.isFinite, value > 0 else { return }
        var style = clip.textStyle ?? TextStyle()
        if clip.scaleTrack?.isActive == true {
            guard style.fontSize.isFinite, style.fontSize > 0 else { return }
            writeScale(into: &clip, newScale: value / style.fontSize)
        } else {
            let staticScale = style.fontScale.isFinite && style.fontScale > 0
                ? style.fontScale
                : TextStyle().fontScale
            style.fontSize = value / staticScale
            clip.textStyle = style
            _ = fitTextClipToContentIfNeeded(
                &clip,
                canvasW: Double(timeline.width),
                canvasH: Double(timeline.height)
            )
        }
    }

    private func writeScale(into clip: inout Clip, newScale: Double) {
        guard newScale.isFinite, newScale > 0 else { return }
        if clip.mediaType == .text {
            guard clip.scaleTrack?.isActive == true,
                  clip.contains(timelineFrame: activeFrame) else { return }
            let baseScale = clip.textStyle?.fontScale ?? TextStyle().fontScale
            guard baseScale.isFinite, baseScale > 0,
                  clip.transform.width.isFinite, clip.transform.width > 0,
                  clip.transform.height.isFinite, clip.transform.height > 0 else { return }
            let ratio = newScale / baseScale
            clip.upsertKeyframe(
                in: \.scaleTrack,
                frame: activeFrame,
                value: AnimPair(
                    a: clip.transform.width * ratio,
                    b: clip.transform.height * ratio
                )
            )
            return
        }
        let aspect = mediaCanvasAspect(for: clip) ?? 1.0
        let w = newScale
        let h = newScale / aspect
        if clip.scaleTrack?.isActive == true {
            guard clip.contains(timelineFrame: activeFrame) else { return }
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
            if clip.contains(timelineFrame: frame) {
                let tl = newTransform.topLeft
                clip.upsertKeyframe(in: \.positionTrack, frame: frame, value: AnimPair(a: tl.x, b: tl.y))
            }
        } else {
            clip.transform.centerX = newTransform.centerX
            clip.transform.centerY = newTransform.centerY
        }
        if clip.scaleTrack?.isActive == true {
            if clip.contains(timelineFrame: frame) {
                clip.upsertKeyframe(in: \.scaleTrack, frame: frame, value: AnimPair(a: newTransform.width, b: newTransform.height))
            }
        } else {
            clip.transform.width = newTransform.width
            clip.transform.height = newTransform.height
        }
        if clip.rotationTrack?.isActive == true {
            if clip.contains(timelineFrame: frame) {
                clip.upsertKeyframe(in: \.rotationTrack, frame: frame, value: newTransform.rotation)
            }
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
            guard clip.contains(timelineFrame: activeFrame) else { return }
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
