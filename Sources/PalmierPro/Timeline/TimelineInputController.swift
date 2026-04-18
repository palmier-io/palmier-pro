import AppKit

/// Owns all mouse/cursor/drag logic for the timeline.
/// Communicates back to TimelineView via `view.needsDisplay = true`.
/// Uses delta-only drag model: never mutates EditorViewModel during drag.
@MainActor
final class TimelineInputController {
    unowned let editor: EditorViewModel
    unowned let view: TimelineView

    private(set) var dragState: DragState = .idle
    private(set) var snapIndicatorX: Double?
    private(set) var razorPreviewFrame: Int?
    private var snapState = SnapEngine.SnapState()

    init(editor: EditorViewModel, view: TimelineView) {
        self.editor = editor
        self.view = view
    }

    // MARK: - Mouse down

    func mouseDown(with event: NSEvent, geometry: TimelineGeometry) {
        let point = view.convert(event.locationInWindow, from: nil)
        let scrollOffsetY = view.enclosingScrollView?.contentView.bounds.origin.y ?? 0

        // Any click on the timeline switches back to the Timeline preview tab
        if editor.activePreviewTab != .timeline {
            editor.selectPreviewTab(id: PreviewTab.timeline.id)
        }

        // Ruler area — scrub playhead
        if point.y >= scrollOffsetY && point.y < scrollOffsetY + geometry.rulerHeight {
            dragState = .scrubPlayhead
            editor.isScrubbing = true
            scrubToFrame(geometry.frameAt(x: point.x))
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
            } else if isOption {
                // Override: select only the clicked clip regardless of link group.
                editor.selectedClipIds = [clip.id]
            } else if !editor.selectedClipIds.contains(clip.id) {
                editor.selectedClipIds = linkedOn ? editor.expandToLinkGroup([clip.id]) : [clip.id]
            }

            // Determine drag mode: trim left, trim right, or move
            let localX = point.x - rect.minX
            if localX <= Trim.handleWidth {
                dragState = .trimLeft(DragState.TrimDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalTrimStart: clip.trimStartFrame,
                    originalTrimEnd: clip.trimEndFrame,
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    isImage: clip.mediaType == .image,
                    propagateToLinked: linkedOn
                ))
            } else if localX >= rect.width - Trim.handleWidth {
                dragState = .trimRight(DragState.TrimDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalTrimStart: clip.trimStartFrame,
                    originalTrimEnd: clip.trimEndFrame,
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    isImage: clip.mediaType == .image,
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
                    dropTarget: .existingTrack(hit.trackIndex)
                ))
            }
        } else {
            // Empty space — start marquee
            if !event.modifierFlags.contains(.shift) {
                editor.selectedClipIds.removeAll()
            }
            dragState = .marquee(DragState.MarqueeDrag(origin: point, baseSelection: editor.selectedClipIds))
        }

        snapState = SnapEngine.SnapState() // Reset sticky snap for new drag
        view.needsDisplay = true
    }

    // MARK: - Mouse dragged

    func mouseDragged(with event: NSEvent, geometry: TimelineGeometry) {
        let point = view.convert(event.locationInWindow, from: nil)
        let frame = geometry.frameAt(x: point.x)

        switch dragState {
        case .scrubPlayhead:
            scrubToFrame(frame)

        case .moveClip(var drag):
            let candidateFrame = frame - drag.grabOffsetFrames
            let allDraggedIds = Set(drag.all.map(\.clipId))
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: allDraggedIds
            )

            let clipDuration = editor.timeline.tracks
                .flatMap(\.clips)
                .first(where: { $0.id == drag.lead.clipId })?
                .durationFrames ?? 0

            if let snap = SnapEngine.findSnap(
                position: candidateFrame,
                probeOffsets: [0, clipDuration],
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
            // Vertical movement affects only the grabbed clip — a linked
            // partner keeps its own track and just follows horizontally.
            let rawTarget = geometry.dropTargetAt(y: point.y)
            if case .existingTrack(let targetTrack) = rawTarget {
                let tracks = editor.timeline.tracks
                let leadType = tracks[drag.lead.originalTrack].type
                let landedTrack = tracks.indices.contains(targetTrack)
                    && tracks[targetTrack].type.isCompatible(with: leadType)
                    ? targetTrack : drag.lead.originalTrack
                drag.dropTarget = .existingTrack(landedTrack)
            } else {
                drag.dropTarget = rawTarget
            }
            dragState = .moveClip(drag)

        case .trimLeft(var drag):
            let candidateStart = frame
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: [drag.clipId]
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
            let minDelta = -drag.originalTrimStart
            drag.deltaFrames = max(minDelta, min(maxDelta, delta))
            dragState = .trimLeft(drag)

        case .trimRight(var drag):
            let originalEndFrame = drag.originalStartFrame + drag.originalDuration
            let candidateEnd = max(drag.originalStartFrame + 1, frame)
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: [drag.clipId]
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
            if drag.isImage {
                drag.deltaFrames = max(minDelta, drag.deltaFrames)
            } else {
                let maxDelta = drag.originalTrimEnd
                drag.deltaFrames = max(minDelta, min(maxDelta, drag.deltaFrames))
            }
            dragState = .trimRight(drag)

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
            // Clamp the group delta so no clip ends up at a negative frame.
            let minOrigFrame = drag.all.map(\.originalFrame).min()!
            let clampedDelta = max(-minOrigFrame, drag.deltaFrames)
            let trackDelta: Int = {
                if case .existingTrack(let idx) = drag.dropTarget {
                    return idx - drag.lead.originalTrack
                }
                return 0
            }()

            // No-op: lead didn't move and there's no new track to create.
            if case .existingTrack = drag.dropTarget,
               trackDelta == 0, drag.deltaFrames == 0 {
                break
            }

            switch drag.dropTarget {
            case .existingTrack:
                // Lead changes track; companions keep their own.
                editor.moveClips(drag.all.map { p in
                    let destTrack = drag.isLead(p) ? p.originalTrack + trackDelta : p.originalTrack
                    return (p.clipId, destTrack, p.originalFrame + clampedDelta)
                })
            case .newTrackAt(let insertIndex):
                // Insert a new track for the lead, then move. Companions that
                // sat at or below the insertion index shift down by 1.
                editor.undoManager?.beginUndoGrouping()
                let clipType = editor.timeline.tracks[drag.lead.originalTrack].type
                let newIdx = editor.insertTrack(at: insertIndex, type: clipType, label: clipType.trackLabel)
                let moves: [(String, Int, Int)] = drag.all.map { p in
                    if drag.isLead(p) {
                        return (p.clipId, newIdx, p.originalFrame + clampedDelta)
                    }
                    let shifted = p.originalTrack >= newIdx ? p.originalTrack + 1 : p.originalTrack
                    return (p.clipId, shifted, p.originalFrame + clampedDelta)
                }
                editor.moveClips(moves)
                editor.undoManager?.endUndoGrouping()
                editor.undoManager?.setActionName("Move Clip to New Track")
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

        case .marquee:
            break

        case .scrubPlayhead:
            editor.isScrubbing = false

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

        // Ruler area — show pointing hand for scrub affordance
        if point.y >= scrollOffsetY && point.y < scrollOffsetY + geometry.rulerHeight {
            NSCursor.pointingHand.set()
            razorPreviewFrame = nil
            return
        }

        // Razor tool: show preview line
        if editor.toolMode == .razor && point.y >= scrollOffsetY + geometry.rulerHeight {
            var frame = geometry.frameAt(x: point.x)
            // Snap razor to playhead
            let snapThreshold = max(1, Int(Snap.thresholdPixels / geometry.pixelsPerFrame))
            if abs(frame - editor.currentFrame) <= snapThreshold {
                frame = editor.currentFrame
            }
            razorPreviewFrame = frame
            NSCursor.crosshair.set()
            view.needsDisplay = true
            return
        }
        razorPreviewFrame = nil

        let trackIndex = geometry.trackAt(y: point.y)

        if let hit = hitTestClip(at: point, trackIndex: trackIndex, geometry: geometry) {
            let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
            let rect = geometry.clipRect(for: clip, trackIndex: hit.trackIndex)
            let localX = point.x - rect.minX
            if localX <= Trim.handleWidth || localX >= rect.width - Trim.handleWidth {
                NSCursor.resizeLeftRight.set()
                return
            }
        }
        NSCursor.arrow.set()
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

        // After zoom, scroll so the same frame stays under cursor
        if let scrollView = view.enclosingScrollView {
            let newXForFrame = frameUnderCursor * editor.zoomScale
            let scrollX = max(0, newXForFrame - cursorViewportX)
            let origin = scrollView.contentView.bounds.origin
            scrollView.contentView.setBoundsOrigin(NSPoint(x: scrollX, y: origin.y))
        }

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

    private func scrubToFrame(_ frame: Int) {
        editor.seekToFrame(frame)
    }
}
