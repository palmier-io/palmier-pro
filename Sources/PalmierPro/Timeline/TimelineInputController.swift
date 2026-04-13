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

            if event.modifierFlags.contains(.shift) {
                if editor.selectedClipIds.contains(clip.id) {
                    editor.selectedClipIds.remove(clip.id)
                } else {
                    editor.selectedClipIds.insert(clip.id)
                }
            } else if !editor.selectedClipIds.contains(clip.id) {
                editor.selectedClipIds = [clip.id]
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
                    isImage: clip.mediaType == .image
                ))
            } else if localX >= rect.width - Trim.handleWidth {
                dragState = .trimRight(DragState.TrimDrag(
                    clipId: clip.id,
                    trackIndex: hit.trackIndex,
                    originalTrimStart: clip.trimStartFrame,
                    originalTrimEnd: clip.trimEndFrame,
                    originalStartFrame: clip.startFrame,
                    originalDuration: clip.durationFrames,
                    isImage: clip.mediaType == .image
                ))
            } else {
                let grabFrame = geometry.frameAt(x: point.x)
                var companions: [DragState.CompanionClip] = []
                for (ti, track) in editor.timeline.tracks.enumerated() {
                    for c in track.clips where c.id != clip.id && editor.selectedClipIds.contains(c.id) {
                        companions.append(.init(clipId: c.id, originalTrack: ti, originalFrame: c.startFrame))
                    }
                }
                dragState = .moveClip(DragState.MoveClipDrag(
                    clipId: clip.id,
                    originalTrack: hit.trackIndex,
                    originalFrame: clip.startFrame,
                    grabOffsetFrames: grabFrame - clip.startFrame,
                    dropTarget: .existingTrack(hit.trackIndex),
                    companions: companions
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
            let allDraggedIds = Set([drag.clipId] + drag.companions.map(\.clipId))
            let targets = SnapEngine.collectTargets(
                tracks: editor.timeline.tracks,
                playheadFrame: editor.currentFrame,
                excludeClipIds: allDraggedIds
            )
            if let snap = SnapEngine.findSnap(
                position: candidateFrame,
                targets: targets,
                state: &snapState,
                baseThreshold: Snap.thresholdPixels,
                pixelsPerFrame: geometry.pixelsPerFrame
            ) {
                snapIndicatorX = snap.x
                drag.deltaFrames = snap.frame - drag.originalFrame
            } else {
                snapIndicatorX = nil
                drag.deltaFrames = candidateFrame - drag.originalFrame
            }
            // Multi-clip drag: clamp vertical movement so no clip overflows
            // the track list, and block moves that would land on incompatible types.
            let rawTarget = geometry.dropTargetAt(y: point.y)
            if drag.companions.isEmpty {
                drag.dropTarget = rawTarget
            } else if case .existingTrack(let targetTrack) = rawTarget {
                let trackDelta = targetTrack - drag.originalTrack
                let allTracks = [drag.originalTrack] + drag.companions.map(\.originalTrack)
                let minTrack = allTracks.min()!
                let maxTrack = allTracks.max()!
                let trackCount = editor.timeline.tracks.count
                var clamped = max(-minTrack, min(trackCount - 1 - maxTrack, trackDelta))
                let tracks = editor.timeline.tracks
                let typeOk = allTracks.allSatisfy { orig in
                    let dest = orig + clamped
                    return tracks.indices.contains(dest) && tracks[dest].type.isCompatible(with: tracks[orig].type)
                }
                if !typeOk { clamped = 0 }
                drag.dropTarget = .existingTrack(drag.originalTrack + clamped)
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
            let targetFrame = max(0, drag.originalFrame + drag.deltaFrames)
            let trackDelta = {
                switch drag.dropTarget {
                case .existingTrack(let idx): return idx - drag.originalTrack
                case .newTrackAt: return 0
                }
            }()

            if drag.companions.isEmpty {
                switch drag.dropTarget {
                case .existingTrack(let trackIndex):
                    if trackIndex != drag.originalTrack || targetFrame != drag.originalFrame {
                        editor.moveClip(clipId: drag.clipId, toTrack: trackIndex, toFrame: targetFrame)
                    }
                case .newTrackAt(let insertIndex):
                    let clipType = editor.timeline.tracks[drag.originalTrack].type
                    editor.moveClipToNewTrack(clipId: drag.clipId, insertAt: insertIndex, clipType: clipType, toFrame: targetFrame)
                }
            } else if drag.deltaFrames != 0 || trackDelta != 0 {
                // Clamp delta so no clip goes below frame 0
                let allClips = [DragState.CompanionClip(clipId: drag.clipId, originalTrack: drag.originalTrack, originalFrame: drag.originalFrame)] + drag.companions
                let minOrigFrame = allClips.map(\.originalFrame).min()!
                let clampedDelta = max(-minOrigFrame, drag.deltaFrames)
                editor.moveClips(allClips.map { ($0.clipId, $0.originalTrack + trackDelta, $0.originalFrame + clampedDelta) })
            }

        case .trimLeft(let drag):
            if drag.deltaFrames != 0 {
                let newTrimStart = drag.originalTrimStart + drag.deltaFrames
                editor.trimClip(
                    clipId: drag.clipId,
                    trimStartFrame: newTrimStart,
                    trimEndFrame: drag.originalTrimEnd
                )
            }

        case .trimRight(let drag):
            if drag.deltaFrames != 0 {
                let newTrimEnd = drag.originalTrimEnd - drag.deltaFrames
                editor.trimClip(
                    clipId: drag.clipId,
                    trimStartFrame: drag.originalTrimStart,
                    trimEndFrame: newTrimEnd
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

        view.needsDisplay = true
    }

    // MARK: - Hit testing

    func hitTestClip(
        at point: NSPoint,
        trackIndex: Int,
        geometry: TimelineGeometry
    ) -> (trackIndex: Int, clipIndex: Int)? {
        guard editor.timeline.tracks.indices.contains(trackIndex) else { return nil }
        for (ci, clip) in editor.timeline.tracks[trackIndex].clips.enumerated() {
            if geometry.clipRect(for: clip, trackIndex: trackIndex).contains(point) {
                return (trackIndex, ci)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func scrubToFrame(_ frame: Int) {
        editor.seekToFrame(frame)
    }
}
