import Foundation
struct TimelineMarkerUpdateRequest {
    var id: String
    var name: String?
    var startFrame: Int?
    var durationFrames: Int?
    var color: TextStyle.RGBA?
    var comment: String?
}
struct TimelineMarkerChangeReceipt {
    var created: [TimelineMarker]
    var updated: [TimelineMarker]
    var deletedIds: [String]
}
extension EditorViewModel {
    func timelineMarker(id: String) -> TimelineMarker? {
        timeline.markers.first { $0.id == id }
    }

    func displayedTimelineMarkers(preview: TimelineMarker? = nil) -> [TimelineMarker] {
        var markers = timeline.markers
        if let preview, let index = markers.firstIndex(where: { $0.id == preview.id }) {
            markers[index] = preview
        }
        var displayed: [TimelineMarker] = []
        for marker in markers {
            guard let clipId = marker.clipId else { displayed.append(marker); continue }
            guard let clip = clipFor(id: clipId), let copy = projected(marker, on: clip) else { continue }
            displayed.append(copy)
        }
        return displayed.sorted { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
    }
    func timelineMarkerSnapFrames(
        excludingClipIds: Set<String> = [],
        excludingMarkerIds: Set<String> = []
    ) -> [Int] {
        var frames = Set<Int>()
        for marker in displayedTimelineMarkers()
        where !excludingMarkerIds.contains(marker.id)
            && (marker.clipId.map({ !excludingClipIds.contains($0) }) ?? true) {
            frames.insert(marker.startFrame)
            if marker.isRange { frames.insert(marker.endFrame) }
        }
        return frames.sorted()
    }
    private func projected(_ marker: TimelineMarker, on clip: Clip) -> TimelineMarker? {
        let sourceStart = clip.trimStartFrame
        let sourceEnd = sourceStart + clip.sourceFramesConsumed
        var copy = marker
        if marker.isRange {
            let start = max(sourceStart, marker.startFrame)
            let end = min(sourceEnd, marker.endFrame)
            guard start < end else { return nil }
            copy.startFrame = clip.markerTimelineFrame(at: start)
            let timelineEnd = clip.markerTimelineFrame(at: end)
            copy.durationFrames = max(1, timelineEnd - copy.startFrame)
        } else {
            guard marker.startFrame >= sourceStart, marker.startFrame < sourceEnd else { return nil }
            copy.startFrame = clip.markerTimelineFrame(at: marker.startFrame)
        }
        return copy
    }

    @discardableResult
    func addTimelineMarkerAtSelection() -> TimelineMarker? {
        guard case .timeline = activePreviewTab else {
            refuseWithToast(L10n.string("Select the timeline to add a marker."))
            return nil
        }
        let range = validSelectedTimelineRange
        let selected = timeline.tracks.flatMap(\.clips).filter { selectedClipIds.contains($0.id) }
        let selectedAtPlayhead = selected.filter {
            $0.contains(timelineFrame: activeFrame)
        }
        let sourceClip = Set(selectedAtPlayhead.map(\.mediaRef)).count == 1
            ? selectedAtPlayhead.first(where: { $0.mediaType != .audio }) ?? selectedAtPlayhead.first
            : nil
        guard selected.isEmpty || sourceClip != nil else {
            refuseWithToast(L10n.string("Move the playhead over the selected clip to add a marker."))
            return nil
        }
        let sourceFrame = sourceClip.map { $0.markerSourceFrame(at: activeFrame) }
        let marker = TimelineMarker(
            clipId: sourceClip?.id,
            name: L10n.string("Marker"),
            startFrame: sourceFrame ?? range?.startFrame ?? activeFrame,
            durationFrames: sourceClip == nil ? range.map { $0.endFrame - $0.startFrame } ?? 0 : 0
        )
        do {
            let created = try changeTimelineMarkers(
                creates: [marker],
                actionName: "Add Marker"
            ).created.first
            selectedTimelineMarkerIds = Set(created.map { [$0.id] } ?? [])
            selectedClipIds.removeAll()
            selectedGap = nil
            selectedTimelineRange = nil
            if let id = created?.id { onPresentTimelineMarkerEditor?(id) }
            return created
        } catch {
            refuseWithToast(L10n.string("Couldn't add marker."))
            return nil
        }
    }

    @discardableResult
    func changeTimelineMarkers(
        creates: [TimelineMarker] = [],
        updates: [TimelineMarkerUpdateRequest] = [],
        deleteIds: [String] = [],
        actionName: String
    ) throws -> TimelineMarkerChangeReceipt {
        let deleteSet = Set(deleteIds)
        guard deleteSet.count == deleteIds.count else { throw TimelineMarkerValidationError.invalidRange }
        let before = timeline.markers
        var next = before
        guard deleteSet.isSubset(of: Set(next.map(\.id))) else {
            throw TimelineMarkerValidationError.invalidRange
        }

        var updated: [TimelineMarker] = []
        for request in updates {
            guard !deleteSet.contains(request.id) else {
                throw TimelineMarkerValidationError.invalidRange
            }
            guard let index = next.firstIndex(where: { $0.id == request.id }) else {
                throw TimelineMarkerValidationError.invalidRange
            }
            let marker = try applying(request, to: next[index])
            if marker != next[index] { next[index] = marker; updated.append(marker) }
        }

        next.removeAll { deleteSet.contains($0.id) }
        let created = try creates.map(validatedTimelineMarker)
        next += created
        next.sort { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
        guard next != before else {
            return TimelineMarkerChangeReceipt(created: [], updated: [], deletedIds: [])
        }

        timeline.markers = next
        registerTimelineMarkerSwap(undoMarkers: before, redoMarkers: next, actionName: actionName)
        selectedTimelineMarkerIds.subtract(deleteSet)
        return TimelineMarkerChangeReceipt(created: created, updated: updated, deletedIds: deleteIds)
    }

    func deleteSelectedTimelineMarker() {
        guard !selectedTimelineMarkerIds.isEmpty else { return }
        do {
            _ = try changeTimelineMarkers(
                deleteIds: Array(selectedTimelineMarkerIds),
                actionName: selectedTimelineMarkerIds.count == 1 ? "Delete Marker" : "Delete Markers"
            )
        } catch {
            refuseWithToast(L10n.string("Couldn't delete marker."))
        }
    }

    private func applying(_ request: TimelineMarkerUpdateRequest, to original: TimelineMarker) throws -> TimelineMarker {
        var marker = original
        if let name = request.name { marker.name = name }
        if let startFrame = request.startFrame { marker.startFrame = startFrame }
        if let durationFrames = request.durationFrames { marker.durationFrames = durationFrames }
        if let color = request.color { marker.color = color }
        if let comment = request.comment { marker.comment = comment }
        return try validatedTimelineMarker(marker)
    }

    private func validatedTimelineMarker(_ marker: TimelineMarker) throws -> TimelineMarker {
        let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= TimelineMarker.maximumNameLength,
              name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw TimelineMarkerValidationError.invalidName
        }
        guard marker.comment.count <= TimelineMarker.maximumCommentLength else {
            throw TimelineMarkerValidationError.invalidComment
        }
        let end = marker.startFrame.addingReportingOverflow(marker.durationFrames)
        let components = [marker.color.r, marker.color.g, marker.color.b, marker.color.a]
        guard marker.startFrame >= 0, marker.durationFrames >= 0, !end.overflow,
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              marker.clipId.map({ clipFor(id: $0) != nil }) ?? true else {
            throw TimelineMarkerValidationError.invalidRange
        }
        var marker = marker
        marker.name = name
        return marker
    }

    private func registerTimelineMarkerSwap(
        undoMarkers: [TimelineMarker],
        redoMarkers: [TimelineMarker],
        actionName: String
    ) {
        registerTimelineUndo(actionName) { vm in
            vm.timeline.markers = undoMarkers
            vm.selectedTimelineMarkerIds.formIntersection(undoMarkers.map(\.id))
            vm.registerTimelineMarkerSwap(
                undoMarkers: redoMarkers, redoMarkers: undoMarkers,
                actionName: actionName
            )
        }
    }
}
