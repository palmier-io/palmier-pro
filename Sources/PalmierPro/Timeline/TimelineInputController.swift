import AppKit
@MainActor
final class TimelineInputController {
    unowned let editor: EditorViewModel
    unowned let view: TimelineView

    private(set) var dragState: DragState = .idle
    private var snapIndicatorX: Double? {
        didSet { view.snapOverlay.setLocalX(snapIndicatorX) }
    }
    private(set) var razorPreviewFrame: Int?
    private var snapState = SnapEngine.SnapState()
    private var razorSnapState = SnapEngine.SnapState()
    private var scrubWasPlaying = false

    init(editor: EditorViewModel, view: TimelineView) {
        self.editor = editor
        self.view = view
    }

    // MARK: - Mouse down

    func mouseDown(with event: NSEvent, geometry: TimelineGeometry) {
        let point = view.convert(event.locationInWindow, from: nil)
        let scrollOffsetY = view.enclosingScrollView?.contentView.bounds.origin.y ?? 0

        if event.clickCount == 2,
           point.y >= scrollOffsetY + geometry.rulerHeight {
            let ti = geometry.trackAt(y: point.y)
            if let hit = hitTestClip(at: point, trackIndex: ti, geometry: geometry) {
                let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
                if let asset = editor.mediaAssets.first(where: { $0.id == clip.mediaRef }) {
                    editor.selectedClipIds.removeAll()
                    editor.selectedMediaAssetIds = [asset.id]
                    editor.openPreviewTab(for: asset)
                    editor.mediaPanelRevealAssetId = asset.id
                    dragState = .idle
                    view.needsDisplay = true
                    return
                }
            }
        }

        if editor.activePreviewTab != .timeline {
            editor.selectPreviewTab(id: PreviewTab.timeline.id)
        }

        if point.y >= scrollOffsetY && point.y < scrollOffsetY + geometry.rulerHeight {
            beginPlayheadScrub(at: geometry.frameAt(x: point.x))
            return
        }

        let trackIndex = geometry.trackAt(y: point.y)

        if editor.toolMode == .razor {
            if let hit = hitTestClip(at: point, trackIndex: trackIndex, geometry: geometry) {
                let clickFrame = razorPreviewFrame ?? geometry.frameAt(x: point.x)
                let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
                editor.splitClip(clipId: clip.id, atFrame: clickFrame)
                view.needsDisplay = true
            }
            return
        }

        if let hit = hitTestClip(at: point, trackIndex: trackIndex, geometry: geometry) {
            let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
            let rect = geometry.clipRect(for: clip, trackIndex: hit.trackIndex)
            let isShift = event.modifierFlags.contains(.shift)
            let isOption = event.modifierFlags.contains(.option)
            // Linked behavior is always on; Option is the per-drag override.
            let linkedOn = !isOption

            if isShift {
                if editor.selectedClipIds.contains(clip.id) {
                    if linkedOn {
                        editor.selectedClipIds.subtract(editor.expandToLinkGroup([clip.id]))
                    } else {
                        editor.selectedClipIds.remove(clip.id)
                    }
                } else if linkedOn {
                    editor.selectedClipIds.formUnion(editor.expandToLinkGroup([clip.id]))
                } else {
                    editor.selectedClipIds.insert(clip.id)
                }
            } else if isOption, !editor.selectedClipIds.contains(clip.id) {
                editor.selectedClipIds = [clip.id]
            } else if !isOption, !editor.selectedClipIds.contains(clip.id) {
                editor.selectedClipIds = linkedOn ? editor.expandToLinkGroup([clip.id]) : [clip.id]
            }

            let localX = point.x - rect.minX
            let isCommand = event.modifierFlags.contains(.command)

            if clip.mediaType == .audio,
               let edge = audioFadeKneeHit(at: point, clip: clip, clipRect: rect) {
                let originalFrames = edge == .left ? clip.audioFadeInFrames : clip.audioFadeOutFrames
                dragState = .audioFadeKnee(DragState.AudioFadeKneeDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    edge: edge,
                    originalFrames: originalFrames,
                    grabFrame: geometry.frameAt(x: point.x),
                    currentFrames: originalFrames
                ))
            } else if clip.mediaType == .audio,
               let kfFrame = audioVolumeKfHit(at: point, clip: clip, clipRect: rect) {
                let kfOffset = kfFrame - clip.startFrame
                let dB = clip.volumeTrack?.keyframes.first(where: { $0.frame == kfOffset })?.value ?? 0
                dragState = .audioVolumeKf(DragState.AudioVolumeKfDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalFrame: kfFrame,
                    originalDb: dB,
                    grabFrame: geometry.frameAt(x: point.x),
                    currentFrame: kfFrame,
                    currentDb: dB
                ))
            } else if isCommand, clip.mediaType == .audio,
                      addVolumeKeyframeOnClick(at: point, clip: clip, clipRect: rect) {
                dragState = .idle
            } else if !isOption, localX <= Trim.handleWidth {
                dragState = .trimLeft(DragState.TrimDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalTrimStart: clip.trimStartFrame,
                    originalTrimEnd: clip.trimEndFrame,
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    hasNoSourceMedia: clip.mediaType == .image || clip.mediaType == .text,
                    propagateToLinked: linkedOn
                ))
            } else if !isOption, localX >= rect.width - Trim.handleWidth {
                dragState = .trimRight(DragState.TrimDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalTrimStart: clip.trimStartFrame,
                    originalTrimEnd: clip.trimEndFrame,
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    hasNoSourceMedia: clip.mediaType == .image || clip.mediaType == .text,
                    propagateToLinked: linkedOn
                ))
            } else {
                let grabFrame = geometry.frameAt(x: point.x)
                var companions: [DragState.Participant] = []
                for (ti, track) in editor.timeline.tracks.enumerated() {
                    for c in track.clips where c.id != clip.id && editor.selectedClipIds.contains(c.id) {
                        companions.append(.init(clipId: c.id, originalTrack: ti, originalFrame: c.startFrame))
                    }
                }
                dragState = .moveClip(DragState.MoveClipDrag(
                    lead: .init(clipId: clip.id, originalTrack: hit.trackIndex, originalFrame: clip.startFrame),
                    companions: companions,
                    grabOffsetFrames: grabFrame - clip.startFrame,
                    dropTarget: .existingTrack(hit.trackIndex),
                    isDuplicate: isOption
                ))
            }
        } else {
            if !event.modifierFlags.contains(.shift) {
                editor.selectedClipIds.removeAll()
            }
            dragState = .marquee(DragState.MarqueeDrag(origin: point, baseSelection: editor.selectedClipIds))
        }

        snapState = SnapEngine.SnapState()
        view.needsDisplay = true
    }

    // MARK: - Mouse dragged

    func mouseDragged(with event: NSEvent, geometry: TimelineGeometry) {
        let point = view.convert(event.locationInWindow, from: nil)
        let frame = geometry.frameAt(x: point.x)

        switch dragState {
        case .scrubPlayhead:
            snapIndicatorX = nil
            scrubToFrame(frame)
            view.updatePlayheadLayer()
            return

        case .moveClip(var drag):
            let candidateFrame = frame - drag.grabOffsetFrames
            let allDraggedIds = Set(drag.all.map(\.clipId))
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: allDraggedIds,
                includePlayhead: true
            )

            // Let any selected edge drive snapping, not just the lead start.
            let clipsById = Dictionary(uniqueKeysWithValues:
                editor.timeline.tracks.flatMap(\.clips).map { ($0.id, $0) })
            var probeOffsets: [Int] = []
            for p in drag.all {
                guard let c = clipsById[p.clipId] else { continue }
                let baseOffset = p.originalFrame - drag.lead.originalFrame
                probeOffsets.append(baseOffset)
                probeOffsets.append(baseOffset + c.durationFrames)
            }

            if let snap = SnapEngine.findSnap(
                position: candidateFrame,
                probeOffsets: probeOffsets,
                targets: targets,
                state: &snapState,
                baseThreshold: Snap.thresholdPixels,
                pixelsPerFrame: geometry.pixelsPerFrame
            ) {
                snapIndicatorX = snap.x
                drag.deltaFrames = (snap.frame - snap.probeOffset) - drag.lead.originalFrame
            } else {
                snapIndicatorX = nil
                drag.deltaFrames = candidateFrame - drag.lead.originalFrame
            }
            let minOrigFrame = drag.all.map(\.originalFrame).min() ?? 0
            drag.deltaFrames = max(-minOrigFrame, drag.deltaFrames)
            let rawTarget = geometry.dropTargetAt(y: point.y)
            let row: Int? = {
                if case .existingTrack(let t) = rawTarget { return t }
                return drag.companions.isEmpty ? nil : geometry.trackAt(y: point.y)
            }()
            if let row {
                let clamped = clampedTrackDelta(for: drag, proposed: row - drag.lead.originalTrack)
                drag.dropTarget = .existingTrack(drag.lead.originalTrack + clamped)
            } else {
                drag.dropTarget = rawTarget
            }
            dragState = .moveClip(drag)

        case .trimLeft(var drag):
            let candidateStart = frame
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: [drag.clipId],
                includePlayhead: true
            )
            let snappedStart: Int
            if let snap = SnapEngine.findSnap(
                position: candidateStart,
                targets: targets,
                state: &snapState,
                baseThreshold: Snap.thresholdPixels,
                pixelsPerFrame: geometry.pixelsPerFrame
            ) {
                snapIndicatorX = snap.x
                snappedStart = snap.frame
            } else {
                snapIndicatorX = nil
                snappedStart = candidateStart
            }
            let delta = snappedStart - drag.originalStartFrame
            let maxDelta = drag.originalDuration - 1
            let minDelta = drag.hasNoSourceMedia ? -drag.originalStartFrame : -drag.originalTrimStart
            drag.deltaFrames = max(minDelta, min(maxDelta, delta))
            dragState = .trimLeft(drag)

        case .trimRight(var drag):
            let originalEndFrame = drag.originalStartFrame + drag.originalDuration
            let candidateEnd = max(drag.originalStartFrame + 1, frame)
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: [drag.clipId],
                includePlayhead: true
            )
            let snappedEnd: Int
            if let snap = SnapEngine.findSnap(
                position: candidateEnd,
                targets: targets,
                state: &snapState,
                baseThreshold: Snap.thresholdPixels,
                pixelsPerFrame: geometry.pixelsPerFrame
            ) {
                snapIndicatorX = snap.x
                snappedEnd = snap.frame
            } else {
                snapIndicatorX = nil
                snappedEnd = candidateEnd
            }
            drag.deltaFrames = snappedEnd - originalEndFrame
            // Can't shrink past 1 frame; for non-image clips, can't expand past source material
            let minDelta = -(drag.originalDuration - 1)
            if drag.hasNoSourceMedia {
                drag.deltaFrames = max(minDelta, drag.deltaFrames)
            } else {
                let maxDelta = drag.originalTrimEnd
                drag.deltaFrames = max(minDelta, min(maxDelta, drag.deltaFrames))
            }
            dragState = .trimRight(drag)

        case .audioVolumeKf(let drag):
            dragState = .audioVolumeKf(applyVolumeKfDrag(drag, cursorFrame: frame, cursorY: point.y, geometry: geometry))

        case .audioFadeKnee(let drag):
            dragState = .audioFadeKnee(applyFadeKneeDrag(drag, cursorFrame: frame))

        case .marquee(var marq):
            marq.current = NSRect(
                x: min(marq.origin.x, point.x),
                y: min(marq.origin.y, point.y),
                width: abs(point.x - marq.origin.x),
                height: abs(point.y - marq.origin.y)
            )
            var selected = marq.baseSelection
            for (ti, track) in editor.timeline.tracks.enumerated() {
                for clip in track.clips {
                    if geometry.clipRect(for: clip, trackIndex: ti).intersects(marq.current) {
                        selected.insert(clip.id)
                    }
                }
            }
            if !event.modifierFlags.contains(.option) {
                selected = editor.expandToLinkGroup(selected)
            }
            editor.selectedClipIds = selected
            dragState = .marquee(marq)

        case .idle:
            break
        }

        view.needsDisplay = true
    }

    // MARK: - Mouse up

    func mouseUp(with event: NSEvent, geometry: TimelineGeometry) {
        switch dragState {
        case .moveClip(let drag):
            let minOrigFrame = drag.all.map(\.originalFrame).min()!
            let clampedDelta = max(-minOrigFrame, drag.deltaFrames)
            let trackDelta: Int = {
                if case .existingTrack(let idx) = drag.dropTarget {
                    return idx - drag.lead.originalTrack
                }
                return 0
            }()

            if case .existingTrack = drag.dropTarget,
               trackDelta == 0, drag.deltaFrames == 0 {
                break
            }

            switch drag.dropTarget {
            case .existingTrack:
                let pinned = pinnedCompanionIds(for: drag)
                let moves = drag.all.map { p in
                    let destTrack = pinned.contains(p.clipId) ? p.originalTrack : p.originalTrack + trackDelta
                    return (clipId: p.clipId, toTrack: destTrack, toFrame: p.originalFrame + clampedDelta)
                }
                if drag.isDuplicate {
                    editor.duplicateClipsToPositions(moves)
                } else {
                    editor.moveClips(moves)
                }
            case .newTrackAt(let insertIndex):
                // Existing companions at or below the inserted track shift down.
                editor.undoManager?.beginUndoGrouping()
                let clipType = editor.timeline.tracks[drag.lead.originalTrack].type
                let newIdx = editor.insertTrack(at: insertIndex, type: clipType, label: clipType.trackLabel)
                let moves: [(clipId: String, toTrack: Int, toFrame: Int)] = drag.all.map { p in
                    if drag.isLead(p) {
                        return (p.clipId, newIdx, p.originalFrame + clampedDelta)
                    }
                    let shifted = p.originalTrack >= newIdx ? p.originalTrack + 1 : p.originalTrack
                    return (p.clipId, shifted, p.originalFrame + clampedDelta)
                }
                if drag.isDuplicate {
                    editor.duplicateClipsToPositions(moves)
                    editor.undoManager?.setActionName(moves.count == 1 ? "Duplicate Clip to New Track" : "Duplicate Clips to New Track")
                } else {
                    editor.moveClips(moves)
                    editor.undoManager?.setActionName("Move Clip to New Track")
                }
                editor.undoManager?.endUndoGrouping()
            }

        case .trimLeft(let drag):
            if drag.deltaFrames != 0 {
                editor.commitTrim(
                    clipId: drag.clipId,
                    edge: .left,
                    deltaFrames: drag.deltaFrames,
                    propagateToLinked: drag.propagateToLinked
                )
            }

        case .trimRight(let drag):
            if drag.deltaFrames != 0 {
                editor.commitTrim(
                    clipId: drag.clipId,
                    edge: .right,
                    deltaFrames: drag.deltaFrames,
                    propagateToLinked: drag.propagateToLinked
                )
            }

        case .audioVolumeKf(let drag):
            if drag.currentFrame != drag.originalFrame || drag.currentDb != drag.originalDb {
                editor.commitMoveVolumeKeyframe(clipId: drag.clipId)
            } else {
                editor.revertClipProperty(clipId: drag.clipId)
            }

        case .audioFadeKnee(let drag):
            if drag.currentFrames != drag.originalFrames {
                editor.commitFade(clipId: drag.clipId, edge: drag.edge, frames: drag.currentFrames)
            } else {
                editor.revertClipProperty(clipId: drag.clipId)
            }

        case .marquee:
            break

        case .scrubPlayhead:
            finishPlayheadScrub()

        case .idle:
            break
        }

        dragState = .idle
        snapIndicatorX = nil
        view.needsDisplay = true
    }

    // MARK: - Mouse moved (cursor updates)

    func mouseMoved(with event: NSEvent, geometry: TimelineGeometry) {
        let point = view.convert(event.locationInWindow, from: nil)
        let scrollOffsetY = view.enclosingScrollView?.contentView.bounds.origin.y ?? 0

        if point.y >= scrollOffsetY && point.y < scrollOffsetY + geometry.rulerHeight {
            NSCursor.pointingHand.set()
            razorPreviewFrame = nil
            razorSnapState = SnapEngine.SnapState()
            return
        }

        if editor.toolMode == .razor && point.y >= scrollOffsetY + geometry.rulerHeight {
            let candidate = geometry.frameAt(x: point.x)
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                includePlayhead: true
            )
            if let snap = SnapEngine.findSnap(
                position: candidate,
                targets: targets,
                state: &razorSnapState,
                baseThreshold: Snap.thresholdPixels,
                pixelsPerFrame: geometry.pixelsPerFrame
            ) {
                razorPreviewFrame = snap.frame
            } else {
                razorPreviewFrame = candidate
            }
            NSCursor.crosshair.set()
            view.needsDisplay = true
            return
        }
        razorPreviewFrame = nil
        razorSnapState = SnapEngine.SnapState()

        let trackIndex = geometry.trackAt(y: point.y)

        if let hit = hitTestClip(at: point, trackIndex: trackIndex, geometry: geometry) {
            let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
            let rect = geometry.clipRect(for: clip, trackIndex: hit.trackIndex)
            let localX = point.x - rect.minX
            if Self.isOnTrimZone(localX: localX, clipWidth: rect.width) {
                NSCursor.resizeLeftRight.set()
                return
            }
            if clip.mediaType == .audio,
               audioFadeKneeHit(at: point, clip: clip, clipRect: rect) != nil {
                NSCursor.resizeLeftRight.set()
                return
            }
            if clip.mediaType == .audio,
               audioVolumeKfHit(at: point, clip: clip, clipRect: rect) != nil {
                NSCursor.openHand.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    private static func isOnTrimZone(localX: CGFloat, clipWidth: CGFloat) -> Bool {
        localX <= Trim.handleWidth || localX >= clipWidth - Trim.handleWidth
    }

    func audioVolumeKfHit(at point: NSPoint, clip: Clip, clipRect: NSRect) -> Int? {
        guard let track = clip.volumeTrack, track.isActive else { return nil }
        let geo = view.geometry
        for kf in track.keyframes {
            if geo.audioVolumeKfRect(clip: clip, kfOffset: kf.frame, kfDb: kf.value, in: clipRect).contains(point) {
                return clip.startFrame + kf.frame
            }
        }
        return nil
    }

    func audioFadeKneeHit(at point: NSPoint, clip: Clip, clipRect: NSRect) -> FadeEdge? {
        let geo = view.geometry
        if geo.audioFadeKneeRect(clip: clip, edge: .left, in: clipRect).contains(point) { return .left }
        if geo.audioFadeKneeRect(clip: clip, edge: .right, in: clipRect).contains(point) { return .right }
        return nil
    }

    /// Per-tick handler for `.audioVolumeKf` drags. Clamps within neighbor kf bounds.
    private func applyVolumeKfDrag(
        _ drag: DragState.AudioVolumeKfDrag,
        cursorFrame: Int,
        cursorY: CGFloat,
        geometry: TimelineGeometry
    ) -> DragState.AudioVolumeKfDrag {
        var drag = drag
        guard editor.timeline.tracks.indices.contains(drag.trackIndex),
              let clip = editor.timeline.tracks[drag.trackIndex].clips.first(where: { $0.id == drag.clipId }) else {
            return drag
        }
        let clipRect = geometry.clipRect(for: clip, trackIndex: drag.trackIndex)
        let body = ClipRenderer.audioBodyRect(in: clipRect)

        let curOffset = drag.currentFrame - clip.startFrame
        var leftBound = 0
        var rightBound = clip.durationFrames
        for kf in clip.volumeTrack?.keyframes ?? [] where kf.frame != curOffset {
            if kf.frame < curOffset {
                leftBound = max(leftBound, kf.frame + 1)
            } else {
                rightBound = min(rightBound, kf.frame - 1)
            }
        }
        let proposed = drag.originalFrame + (cursorFrame - drag.grabFrame)
        let newFrame = max(clip.startFrame + leftBound, min(clip.startFrame + rightBound, proposed))
        let newDb = max(VolumeScale.floorDb, min(VolumeScale.ceilingDb, ClipRenderer.db(forY: cursorY, in: body)))

        guard newFrame != drag.currentFrame || newDb != drag.currentDb else { return drag }

        editor.applyMoveVolumeKeyframe(
            clipId: drag.clipId, fromFrame: drag.currentFrame, toFrame: newFrame, newDb: newDb
        )
        drag.currentFrame = newFrame
        drag.currentDb = newDb
        return drag
    }

    /// Per-tick handler for `.audioFadeKnee` drags. Computes the fade length from the cursor.
    private func applyFadeKneeDrag(
        _ drag: DragState.AudioFadeKneeDrag,
        cursorFrame: Int
    ) -> DragState.AudioFadeKneeDrag {
        var drag = drag
        guard editor.timeline.tracks.indices.contains(drag.trackIndex),
              let clip = editor.timeline.tracks[drag.trackIndex].clips.first(where: { $0.id == drag.clipId }) else {
            return drag
        }
        let delta = cursorFrame - drag.grabFrame
        let proposed = drag.edge == .left
            ? drag.originalFrames + delta
            : drag.originalFrames - delta
        let counterFade = drag.edge == .left ? clip.audioFadeOutFrames : clip.audioFadeInFrames
        let cap = max(0, clip.durationFrames - counterFade)
        let clamped = max(0, min(cap, proposed))

        guard clamped != drag.currentFrames else { return drag }
        editor.applyFade(clipId: drag.clipId, edge: drag.edge, frames: clamped)
        drag.currentFrames = clamped
        return drag
    }

    /// Returns true if a kf was added.
    private func addVolumeKeyframeOnClick(at point: NSPoint, clip: Clip, clipRect: NSRect) -> Bool {
        guard clip.durationFrames > 0 else { return false }
        let body = ClipRenderer.audioBodyRect(in: clipRect)
        guard body.contains(point) else { return false }
        let pxPerFrame = clipRect.width / CGFloat(clip.durationFrames)
        let xInClip = point.x - clipRect.minX
        let offset = max(0, min(clip.durationFrames, Int((xInClip / pxPerFrame).rounded())))
        let absFrame = clip.startFrame + offset
        let dB = max(VolumeScale.floorDb, min(VolumeScale.ceilingDb, ClipRenderer.db(forY: point.y, in: body)))
        editor.commitClipProperty(clipId: clip.id) { c in
            c.upsertKeyframe(in: \.volumeTrack, frame: absFrame, value: dB)
        }
        editor.undoManager?.setActionName("Add Keyframe")
        view.needsDisplay = true
        return true
    }

    // MARK: - Scroll wheel (Option+scroll = zoom)

    func scrollWheel(with event: NSEvent, geometry: TimelineGeometry) {
        guard event.modifierFlags.contains(.option) else {
            view.superview?.superview?.scrollWheel(with: event)
            return
        }

        let cursorDocX = view.convert(event.locationInWindow, from: nil).x
        let scrollOrigin = view.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        let cursorViewportX = cursorDocX - scrollOrigin

        let frameUnderCursor = max(0.0, cursorDocX / geometry.pixelsPerFrame)

        let delta = event.scrollingDeltaY * Zoom.scrollSensitivity
        editor.zoomScale = max(editor.minZoomScale, min(Zoom.max, editor.zoomScale + delta))

        if let scrollView = view.enclosingScrollView {
            let newXForFrame = frameUnderCursor * editor.zoomScale
            let scrollX = max(0, newXForFrame - cursorViewportX)
            let origin = scrollView.contentView.bounds.origin
            scrollView.contentView.setBoundsOrigin(NSPoint(x: scrollX, y: origin.y))
        }

        view.markZoomApplied()
        view.updateContentSize()
        view.needsDisplay = true
    }

    // MARK: - Hit testing

    func hitTestClip(
        at point: NSPoint,
        trackIndex: Int,
        geometry: TimelineGeometry
    ) -> ClipLocation? {
        guard editor.timeline.tracks.indices.contains(trackIndex) else { return nil }
        for (ci, clip) in editor.timeline.tracks[trackIndex].clips.enumerated() {
            if geometry.clipRect(for: clip, trackIndex: trackIndex).contains(point) {
                return ClipLocation(trackIndex: trackIndex, clipIndex: ci)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func beginPlayheadScrub(at frame: Int) {
        dragState = .scrubPlayhead
        scrubWasPlaying = editor.isPlaying
        if scrubWasPlaying { editor.pause() }
        editor.isScrubbing = true
        scrubToFrame(frame)
        view.updatePlayheadLayer()
    }

    private func finishPlayheadScrub() {
        let shouldResume = scrubWasPlaying
        let frame = editor.activeFrame
        scrubWasPlaying = false
        editor.isScrubbing = false
        editor.seekToFrame(frame, mode: .exact)
        if shouldResume { editor.resumePlayback() }
    }

    private func scrubToFrame(_ frame: Int) {
        editor.seekToFrame(frame, mode: .interactiveScrub)
    }

    func pinnedCompanionIds(for drag: DragState.MoveClipDrag) -> Set<String> {
        let clips = editor.timeline.tracks.flatMap(\.clips)
        guard let leadLink = clips.first(where: { $0.id == drag.lead.clipId })?.linkGroupId else {
            return []
        }
        return Set(clips.lazy.filter { $0.id != drag.lead.clipId && $0.linkGroupId == leadLink }.map(\.id))
    }

    /// Clamps track movement to valid, type-compatible tracks.
    func clampedTrackDelta(for drag: DragState.MoveClipDrag, proposed: Int) -> Int {
        let tracks = editor.timeline.tracks
        let clipsById = Dictionary(uniqueKeysWithValues: tracks.flatMap(\.clips).map { ($0.id, $0) })
        let pinned = pinnedCompanionIds(for: drag)
        let movers = drag.all.filter { !pinned.contains($0.clipId) }
        let step = proposed >= 0 ? -1 : 1
        var d = proposed
        while d != 0 {
            let ok = movers.allSatisfy { p in
                let dest = p.originalTrack + d
                guard tracks.indices.contains(dest), let c = clipsById[p.clipId] else { return false }
                return tracks[dest].type.isCompatible(with: c.mediaType)
            }
            if ok { return d }
            d += step
        }
        return 0
    }
}
