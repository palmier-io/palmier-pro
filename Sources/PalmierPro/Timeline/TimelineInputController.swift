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
    private var playheadAutoScrollTimer: Timer?
    private var playheadAutoScrollWindowPoint: NSPoint?

    private enum TimelineRangeEdge {
        case start
        case end
    }

    private static let timelineRangeEdgeHitSlop: CGFloat = 8

    init(editor: EditorViewModel, view: TimelineView) {
        self.editor = editor
        self.view = view
    }

    // MARK: - Mouse down


    /// Nest trim limits come from the child's live length, not creation time.
    private func effectiveTrimEnd(for clip: Clip) -> Int {
        guard clip.sourceClipType == .sequence, let child = editor.timeline(for: clip.mediaRef) else {
            return clip.trimEndFrame
        }
        return max(0, child.totalFrames - clip.trimStartFrame - clip.durationFrames)
    }

    func mouseDown(with event: NSEvent, geometry: TimelineGeometry) {
        let point = view.convert(event.locationInWindow, from: nil)
        let scrollOffsetY = view.enclosingScrollView?.contentView.bounds.origin.y ?? 0

        if event.clickCount == 2,
           point.y >= scrollOffsetY + geometry.rulerHeight {
            let ti = geometry.trackAt(y: point.y)
            if let hit = hitTestClip(at: point, trackIndex: ti, geometry: geometry) {
                let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
                if clip.sourceClipType == .sequence {
                    editor.activateTimeline(clip.mediaRef)
                    dragState = .idle
                    return
                }
                if let asset = editor.mediaAssets.first(where: { $0.id == clip.mediaRef }) {
                    editor.selectMediaAsset(asset)
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
            let frame = geometry.frameAt(x: point.x)
            if let edge = timelineRangeEdgeHit(at: point, geometry: geometry) {
                beginTimelineRangeEdgeDrag(edge)
            } else if event.modifierFlags.contains(.shift) {
                beginTimelineRangeSelection(at: frame)
            } else {
                beginPlayheadScrub(at: frame)
            }
            return
        }

        let trackIndex = geometry.trackAt(y: point.y)
        editor.selectedGap = nil // re-selected below if this lands in a gap

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

            let localX = point.x - rect.minX
            let onTrimHandle = !isOption && Self.isOnTrimZone(localX: localX, clipWidth: rect.width)
            let rippleTrim = isShift && onTrimHandle

            if rippleTrim {
                if !editor.selectedClipIds.contains(clip.id) {
                    editor.selectedClipIds = linkedOn ? editor.expandToLinkGroup([clip.id]) : [clip.id]
                }
            } else if isShift {
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

            let isCommand = event.modifierFlags.contains(.command)

            if let edge = fadeKneeHit(at: point, clip: clip, clipRect: rect) {
                let originalFrames = clip.fadeFrames(edge)
                dragState = .fadeKnee(DragState.FadeKneeDrag(
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
                    originalTrimEnd: effectiveTrimEnd(for: clip),
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    hasNoSourceMedia: clip.mediaType == .image || clip.mediaType == .text,
                    propagateToLinked: linkedOn,
                    isRipple: rippleTrim
                ))
            } else if !isOption, localX >= rect.width - Trim.handleWidth {
                dragState = .trimRight(DragState.TrimDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalTrimStart: clip.trimStartFrame,
                    originalTrimEnd: effectiveTrimEnd(for: clip),
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    hasNoSourceMedia: clip.mediaType == .image || clip.mediaType == .text,
                    propagateToLinked: linkedOn,
                    isRipple: rippleTrim
                ))
            } else {
                let grabFrame = geometry.frameAt(x: point.x)
                var companions: [DragState.Participant] = []
                for (ti, track) in editor.timeline.tracks.enumerated() {
                    for c in track.clips where c.id != clip.id && editor.selectedClipIds.contains(c.id) {
                        companions.append(.init(
                            clipId: c.id,
                            originalTrackId: track.id,
                            originalTrack: ti,
                            originalFrame: c.startFrame
                        ))
                    }
                }
                dragState = .moveClip(DragState.MoveClipDrag(
                    lead: .init(
                        clipId: clip.id,
                        originalTrackId: editor.timeline.tracks[hit.trackIndex].id,
                        originalTrack: hit.trackIndex,
                        originalFrame: clip.startFrame
                    ),
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
            editor.selectedGap = hitTestGap(at: point, trackIndex: trackIndex, geometry: geometry)
            editor.isMarqueeSelecting = true
            dragState = .marquee(DragState.MarqueeDrag(origin: point, baseSelection: editor.selectedClipIds))
        }

        snapState = SnapEngine.SnapState()
        view.needsDisplay = true
    }

    // MARK: - Mouse dragged

    func mouseDragged(with event: NSEvent, geometry: TimelineGeometry) {
        if case .scrubPlayhead = dragState {
            continuePlayheadScrub(windowPoint: event.locationInWindow)
            return
        }
        stopPlayheadAutoScroll()

        let point = view.convert(event.locationInWindow, from: nil)
        let frame = geometry.frameAt(x: point.x)

        switch dragState {
        case .scrubPlayhead:
            return

        case .timelineRange(let drag):
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                includePlayhead: true,
                beatFrames: editor.beatSnapFrames(for:)
            )
            let rangeEndFrame: Int
            if let snap = SnapEngine.findSnap(
                position: frame,
                targets: targets,
                state: &snapState,
                baseThreshold: Snap.thresholdPixels,
                pixelsPerFrame: geometry.pixelsPerFrame
            ) {
                snapIndicatorX = snap.x
                rangeEndFrame = snap.frame
            } else {
                snapIndicatorX = nil
                rangeEndFrame = frame
            }
            editor.setTimelineRange(startFrame: drag.anchorFrame, endFrame: rangeEndFrame)

        case .moveClip(var drag):
            let candidateFrame = frame - drag.grabOffsetFrames
            let allDraggedIds = Set(drag.all.map(\.clipId))
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: allDraggedIds,
                includePlayhead: true,
                beatFrames: editor.beatSnapFrames(for:)
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
            let cursorTarget = geometry.dropTargetAt(y: point.y)
            if case .existingTrack(let cursorTrack) = cursorTarget {
                let leadTrack = drag.lead.originalTrack
                let clamped = clampedTrackDelta(for: drag, proposed: cursorTrack - leadTrack)
                drag.dropTarget = .existingTrack(leadTrack + clamped)
            } else {
                drag.dropTarget = cursorTarget
            }
            dragState = .moveClip(drag)

        case .trimLeft(var drag):
            let candidateStart = frame
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: [drag.clipId],
                includePlayhead: true,
                beatFrames: editor.beatSnapFrames(for:),
                includeExcludedClipBeats: true
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
                includePlayhead: true,
                beatFrames: editor.beatSnapFrames(for:),
                includeExcludedClipBeats: true
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

        case .fadeKnee(let drag):
            dragState = .fadeKnee(applyFadeKneeDrag(drag, cursorFrame: frame))

        case .marquee(var marq):
            let previousRect = marq.current
            marq.current = NSRect(
                x: min(marq.origin.x, point.x),
                y: min(marq.origin.y, point.y),
                width: abs(point.x - marq.origin.x),
                height: abs(point.y - marq.origin.y)
            )
            if marq.current.width > Layout.dragThreshold || marq.current.height > Layout.dragThreshold,
               editor.selectedGap != nil {
                editor.selectedGap = nil
            }
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
            dragState = .marquee(marq)
            // Touch only what changed.
            view.setNeedsDisplay(previousRect.union(marq.current).insetBy(dx: -2, dy: -2))
            if selected != editor.selectedClipIds {
                let flipped = selected.symmetricDifference(editor.selectedClipIds)
                editor.selectedClipIds = selected
                for (ti, track) in editor.timeline.tracks.enumerated() {
                    for clip in track.clips where flipped.contains(clip.id) {
                        view.setNeedsDisplay(geometry.clipRect(for: clip, trackIndex: ti).insetBy(dx: -2, dy: -2))
                    }
                }
            }
            return

        case .idle:
            break
        }

        view.needsDisplay = true
    }

    // MARK: - Mouse up

    func mouseUp(with event: NSEvent, geometry: TimelineGeometry) {
        stopPlayheadAutoScroll()

        switch dragState {
        case .moveClip(let drag):
            if case .existingTrack(let idx) = drag.dropTarget,
               idx == drag.lead.originalTrack, drag.deltaFrames == 0 {
                break
            }

            let resolved = resolvedMoveParticipants(for: drag)
            guard let resolvedLead = resolved.first(where: { $0.participant.clipId == drag.lead.clipId }) else {
                break
            }
            let minOrigFrame = resolved.map { $0.frame }.min()!
            let frameDelta = max(-minOrigFrame, drag.deltaFrames)
            let pinned = pinnedCompanionIds(for: drag)
            let leadTrack = resolvedLead.trackIndex

            switch drag.dropTarget {
            case .existingTrack:
                // Rigid translation: non-pinned shift by trackDelta; pinned hold their row.
                let delta = drag.dropTargetTrackIndex.map { $0 - leadTrack } ?? 0
                let moves = resolved.map { item in
                    let p = item.participant
                    let toTrack = pinned.contains(p.clipId) ? item.trackIndex : item.trackIndex + delta
                    return (clipId: p.clipId, toTrack: toTrack, toFrame: item.frame + frameDelta)
                }
                commitMoves(moves, isDuplicate: drag.isDuplicate)

            case .newTrackAt(let insertIndex):
                guard let leadTrackType = resolvedLeadTrackType(for: drag) else { break }
                editor.undoManager?.beginUndoGrouping()
                let newIdx = editor.insertTrack(at: insertIndex, type: leadTrackType)
                let moves = resolved.map { item in
                    let p = item.participant
                    let hops = !pinned.contains(p.clipId) && item.trackIndex == leadTrack
                    let shifted = item.trackIndex >= newIdx ? item.trackIndex + 1 : item.trackIndex
                    return (clipId: p.clipId, toTrack: hops ? newIdx : shifted, toFrame: item.frame + frameDelta)
                }
                commitMoves(moves, isDuplicate: drag.isDuplicate)
                editor.undoManager?.setActionName(newTrackActionName(count: moves.count, isDuplicate: drag.isDuplicate))
                editor.undoManager?.endUndoGrouping()
            }

        case .trimLeft(let drag):
            if drag.deltaFrames != 0 {
                if drag.isRipple {
                    editor.rippleTrimClip(clipId: drag.clipId, edge: .left, deltaFrames: drag.deltaFrames, propagateToLinked: drag.propagateToLinked)
                } else {
                    editor.commitTrim(
                        clipId: drag.clipId,
                        edge: .left,
                        deltaFrames: drag.deltaFrames,
                        propagateToLinked: drag.propagateToLinked
                    )
                }
            }

        case .trimRight(let drag):
            if drag.deltaFrames != 0 {
                if drag.isRipple {
                    editor.rippleTrimClip(clipId: drag.clipId, edge: .right, deltaFrames: drag.deltaFrames, propagateToLinked: drag.propagateToLinked)
                } else {
                    editor.commitTrim(
                        clipId: drag.clipId,
                        edge: .right,
                        deltaFrames: drag.deltaFrames,
                        propagateToLinked: drag.propagateToLinked
                    )
                }
            }

        case .audioVolumeKf(let drag):
            if drag.currentFrame != drag.originalFrame || drag.currentDb != drag.originalDb {
                editor.commitMoveVolumeKeyframe(clipId: drag.clipId)
            } else {
                editor.revertClipProperty(clipId: drag.clipId)
            }

        case .fadeKnee(let drag):
            if drag.currentFrames != drag.originalFrames {
                editor.commitFade(clipId: drag.clipId, edge: drag.edge, frames: drag.currentFrames)
            } else {
                editor.revertClipProperty(clipId: drag.clipId)
            }

        case .marquee:
            editor.isMarqueeSelecting = false

        case .scrubPlayhead:
            finishPlayheadScrub()

        case .timelineRange:
            editor.keepValidTimelineRangeOrClear()

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
            if timelineRangeEdgeHit(at: point, geometry: geometry) != nil {
                NSCursor.resizeLeftRight.set()
            } else if event.modifierFlags.contains(.shift) {
                NSCursor.crosshair.set()
            } else {
                NSCursor.pointingHand.set()
            }
            razorPreviewFrame = nil
            razorSnapState = SnapEngine.SnapState()
            return
        }

        if editor.toolMode == .razor && point.y >= scrollOffsetY + geometry.rulerHeight {
            let candidate = geometry.frameAt(x: point.x)
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                includePlayhead: true,
                beatFrames: editor.beatSnapFrames(for:)
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
            if fadeKneeHit(at: point, clip: clip, clipRect: rect) != nil {
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

    func fadeKneeHit(at point: NSPoint, clip: Clip, clipRect: NSRect) -> FadeEdge? {
        let geo = view.geometry
        if geo.fadeKneeRect(clip: clip, edge: .left, in: clipRect).contains(point) { return .left }
        if geo.fadeKneeRect(clip: clip, edge: .right, in: clipRect).contains(point) { return .right }
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
        let body = ClipRenderer.clipBodyRect(in: clipRect)

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

    /// Per-tick handler for `.fadeKnee` drags. Computes the fade length from the cursor.
    private func applyFadeKneeDrag(
        _ drag: DragState.FadeKneeDrag,
        cursorFrame: Int
    ) -> DragState.FadeKneeDrag {
        var drag = drag
        guard editor.timeline.tracks.indices.contains(drag.trackIndex),
              let clip = editor.timeline.tracks[drag.trackIndex].clips.first(where: { $0.id == drag.clipId }) else {
            return drag
        }
        let delta = cursorFrame - drag.grabFrame
        let proposed = drag.edge == .left
            ? drag.originalFrames + delta
            : drag.originalFrames - delta
        let counterEdge: FadeEdge = drag.edge == .left ? .right : .left
        let counterFade = clip.fadeFrames(counterEdge)
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
        let body = ClipRenderer.clipBodyRect(in: clipRect)
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

    // MARK: - Zoom & pan

    /// Option+scroll zooms; Cmd+scroll pans horizontally (maps vertical delta to X, for mouse wheels);
    /// plain scroll pans (forwarded to the scroll view, both axes).
    func scrollWheel(with event: NSEvent, geometry: TimelineGeometry) {
        if event.modifierFlags.contains(.option) {
            let cursorDocX = view.convert(event.locationInWindow, from: nil).x
            applyZoom(factor: exp(event.scrollingDeltaY * Zoom.scrollSensitivity), anchorDocX: cursorDocX)
            return
        }

        if event.modifierFlags.contains(.command), let scrollView = view.enclosingScrollView {
            let raw = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            let delta = raw * Zoom.panSpeed
            let origin = scrollView.contentView.bounds.origin
            let maxX = max(0, view.bounds.width - scrollView.contentView.bounds.width)
            let scrollX = min(maxX, max(0, origin.x - delta))
            scrollView.contentView.setBoundsOrigin(NSPoint(x: scrollX, y: origin.y))
            return
        }

        view.superview?.superview?.scrollWheel(with: event)
    }

    /// Trackpad pinch-to-zoom.
    func magnify(with event: NSEvent) {
        let cursorDocX = view.convert(event.locationInWindow, from: nil).x
        applyZoom(factor: 1.0 + event.magnification * Zoom.magnifySensitivity, anchorDocX: cursorDocX)
    }

    private func applyZoom(factor: Double, anchorDocX: CGFloat) {
        let scrollOrigin = view.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        let anchorViewportX = anchorDocX - scrollOrigin
        let frameUnderCursor = max(0.0, anchorDocX / editor.zoomScale)

        let newScale = max(editor.minZoomScale, min(Zoom.max, editor.zoomScale * factor))
        guard newScale != editor.zoomScale else { return }
        editor.zoomScale = newScale

        if let scrollView = view.enclosingScrollView {
            let scrollX = max(0, frameUnderCursor * editor.zoomScale - anchorViewportX)
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

    /// Empty track space bounded on the right by a clip: `[previousClipEnd, nextClipStart)`.
    func hitTestGap(
        at point: NSPoint,
        trackIndex: Int,
        geometry: TimelineGeometry
    ) -> GapSelection? {
        guard editor.timeline.tracks.indices.contains(trackIndex) else { return nil }
        let top = Double(geometry.trackY(at: trackIndex))
        let bottom = top + Double(geometry.trackHeight(at: trackIndex))
        guard point.y >= top, point.y < bottom else { return nil }

        let frame = geometry.frameAt(x: point.x)
        let clips = editor.timeline.tracks[trackIndex].clips
        guard !clips.contains(where: { frame >= $0.startFrame && frame < $0.endFrame }) else { return nil }
        guard let nextStart = clips.map(\.startFrame).filter({ $0 > frame }).min() else { return nil }
        let prevEnd = clips.map(\.endFrame).filter { $0 <= frame }.max() ?? 0
        return GapSelection(trackIndex: trackIndex, range: FrameRange(start: prevEnd, end: nextStart))
    }

    private func timelineRangeEdgeHit(at point: NSPoint, geometry: TimelineGeometry) -> TimelineRangeEdge? {
        guard let range = editor.validSelectedTimelineRange else { return nil }

        let startX = CGFloat(geometry.xForFrame(range.startFrame))
        let endX = CGFloat(geometry.xForFrame(range.endFrame))
        let startDistance = abs(point.x - startX)
        let endDistance = abs(point.x - endX)
        let nearestDistance = min(startDistance, endDistance)

        guard nearestDistance <= Self.timelineRangeEdgeHitSlop else { return nil }
        return startDistance <= endDistance ? .start : .end
    }

    // MARK: - Helpers

    private func beginPlayheadScrub(at frame: Int) {
        stopPlayheadAutoScroll()
        dragState = .scrubPlayhead
        scrubWasPlaying = editor.isPlaying
        if scrubWasPlaying { editor.pause() }
        editor.isScrubbing = true
        scrubToFrame(frame)
        view.updatePlayheadLayer()
    }

    private func finishPlayheadScrub() {
        stopPlayheadAutoScroll()
        let shouldResume = scrubWasPlaying
        let frame = editor.activeFrame
        scrubWasPlaying = false
        editor.isScrubbing = false
        editor.seekToFrame(frame, mode: .exact)
        if shouldResume { editor.resumePlayback() }
    }

    private func continuePlayheadScrub(windowPoint: NSPoint) {
        playheadAutoScrollWindowPoint = windowPoint
        snapIndicatorX = nil

        let didScroll = view.autoScrollHorizontallyForTimelineDrag(windowPoint: windowPoint)
        let point = view.convert(windowPoint, from: nil)
        let frame = view.geometry.frameAt(x: point.x)
        if frame != editor.playheadState.timelineFrame {
            scrubToFrame(frame)
        }
        view.updatePlayheadLayer()
        view.needsDisplay = true

        if didScroll {
            startPlayheadAutoScroll()
        } else {
            stopPlayheadAutoScroll()
        }
    }

    private func startPlayheadAutoScroll() {
        guard playheadAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: TimelineAutoScroll.interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.tickPlayheadAutoScroll()
            }
        }
        playheadAutoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopPlayheadAutoScroll() {
        playheadAutoScrollTimer?.invalidate()
        playheadAutoScrollTimer = nil
        playheadAutoScrollWindowPoint = nil
    }

    private func tickPlayheadAutoScroll() {
        guard case .scrubPlayhead = dragState,
              let windowPoint = playheadAutoScrollWindowPoint else {
            stopPlayheadAutoScroll()
            return
        }
        continuePlayheadScrub(windowPoint: windowPoint)
    }

    private func beginTimelineRangeEdgeDrag(_ edge: TimelineRangeEdge) {
        guard let range = editor.validSelectedTimelineRange else { return }
        let anchorFrame: Int
        switch edge {
        case .start:
            anchorFrame = range.endFrame
        case .end:
            anchorFrame = range.startFrame
        }
        dragState = .timelineRange(DragState.TimelineRangeDrag(anchorFrame: anchorFrame))
        snapState = SnapEngine.SnapState()
        snapIndicatorX = nil
        editor.selectedGap = nil
    }

    private func beginTimelineRangeSelection(at frame: Int) {
        dragState = .timelineRange(DragState.TimelineRangeDrag(anchorFrame: frame))
        snapState = SnapEngine.SnapState()
        snapIndicatorX = nil
        editor.selectedClipIds.removeAll()
        editor.selectedGap = nil
        editor.setTimelineRange(startFrame: frame, endFrame: frame)
    }

    private func scrubToFrame(_ frame: Int) {
        editor.seekToFrame(frame, mode: .interactiveScrub)
    }

    private func commitMoves(_ moves: [(clipId: String, toTrack: Int, toFrame: Int)], isDuplicate: Bool) {
        if isDuplicate {
            editor.duplicateClipsToPositions(moves)
        } else {
            editor.moveClips(moves)
        }
    }

    private func resolvedMoveParticipants(
        for drag: DragState.MoveClipDrag
    ) -> [(participant: DragState.Participant, trackIndex: Int, frame: Int)] {
        drag.all.compactMap { p in
            guard let loc = editor.findClip(id: p.clipId),
                  editor.timeline.tracks.indices.contains(loc.trackIndex) else { return nil }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            return (participant: p, trackIndex: loc.trackIndex, frame: clip.startFrame)
        }
    }

    private func resolvedLeadTrackType(for drag: DragState.MoveClipDrag) -> ClipType? {
        if let loc = editor.findClip(id: drag.lead.clipId),
           editor.timeline.tracks.indices.contains(loc.trackIndex) {
            return editor.timeline.tracks[loc.trackIndex].type
        }
        if let idx = editor.timeline.tracks.firstIndex(where: { $0.id == drag.lead.originalTrackId }) {
            return editor.timeline.tracks[idx].type
        }
        guard editor.timeline.tracks.indices.contains(drag.lead.originalTrack) else { return nil }
        return editor.timeline.tracks[drag.lead.originalTrack].type
    }

    private func newTrackActionName(count: Int, isDuplicate: Bool) -> String {
        switch (isDuplicate, count) {
        case (true, 1): return "Duplicate Clip to New Track"
        case (true, _): return "Duplicate Clips to New Track"
        default:        return "Move Clip to New Track"
        }
    }

    func pinnedCompanionIds(for drag: DragState.MoveClipDrag) -> Set<String> {
        let tracks = editor.timeline.tracks
        guard let leadTrackType = resolvedLeadTrackType(for: drag) else { return [] }
        let clips = tracks.flatMap(\.clips)
        let leadLink = clips.first(where: { $0.id == drag.lead.clipId })?.linkGroupId
        var pinned: Set<String> = []
        for c in clips where c.id != drag.lead.clipId {
            if let leadLink, c.linkGroupId == leadLink {
                pinned.insert(c.id)
            } else if !leadTrackType.isCompatible(with: c.mediaType) {
                pinned.insert(c.id)
            }
        }
        return pinned
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
