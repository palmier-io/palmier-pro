import Foundation
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
        timeline.markers
            .map { $0.id == preview?.id ? preview ?? $0 : $0 }
            .sorted { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
    }
    func timelineMarkerSnapFrames(excludingMarkerIds: Set<String> = []) -> [Int] {
        let frames = displayedTimelineMarkers()
            .filter { !excludingMarkerIds.contains($0.id) }
            .flatMap { $0.isRange ? [$0.startFrame, $0.endFrame] : [$0.startFrame] }
        return Set(frames).sorted()
    }

    @discardableResult
    func addTimelineMarkerAtSelection() -> TimelineMarker? {
        guard case .timeline = activePreviewTab else {
            refuseWithToast(L10n.string("Select the timeline to add a marker."))
            return nil
        }
        let range = validSelectedTimelineRange
        let marker = TimelineMarker(
            name: nextMarkerName(),
            startFrame: range?.startFrame ?? activeFrame,
            durationFrames: range.map { $0.endFrame - $0.startFrame } ?? 0
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

    private func nextMarkerName() -> String {
        let names = Set(timeline.markers.map(\.name))
        var number = 1
        while names.contains(L10n.string("Marker \(number)")) { number += 1 }
        return L10n.string("Marker \(number)")
    }

    @discardableResult
    func changeTimelineMarkers(
        creates: [TimelineMarker] = [],
        updates: [TimelineMarker] = [],
        deleteIds: [String] = [],
        actionName: String
    ) throws -> TimelineMarkerChangeReceipt {
        let deleteSet = Set(deleteIds)
        let affectedIds = deleteSet.union(updates.map(\.id))
        guard deleteSet.count == deleteIds.count else { throw TimelineMarkerValidationError.invalidRange }
        let before = timeline.markers
        var next = before
        guard deleteSet.isSubset(of: Set(next.map(\.id))) else {
            throw TimelineMarkerValidationError.invalidRange
        }

        var updated: [TimelineMarker] = []
        for marker in try updates.map(validatedTimelineMarker) {
            guard !deleteSet.contains(marker.id) else {
                throw TimelineMarkerValidationError.invalidRange
            }
            guard let index = next.firstIndex(where: { $0.id == marker.id }) else {
                throw TimelineMarkerValidationError.invalidRange
            }
            if marker != next[index] { next[index] = marker; updated.append(marker) }
        }

        next.removeAll { deleteSet.contains($0.id) }
        let created = try creates.map(validatedTimelineMarker)
        next += created
        next.sort { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
        if let preview = timelineMarkerPreview, affectedIds.contains(preview.id) {
            timelineMarkerPreview = nil
        }
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
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
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
            vm.timelineMarkerPreview = nil
            vm.timeline.markers = undoMarkers
            vm.selectedTimelineMarkerIds.formIntersection(undoMarkers.map(\.id))
            vm.registerTimelineMarkerSwap(
                undoMarkers: redoMarkers, redoMarkers: undoMarkers,
                actionName: actionName
            )
        }
    }
}
