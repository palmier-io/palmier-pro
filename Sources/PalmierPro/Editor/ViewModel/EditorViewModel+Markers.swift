import Foundation

struct TimelineMarkerDraft: Sendable, Equatable {
    var frame: Int
    var label: String?
    var color: String?
}

extension EditorViewModel {
    @discardableResult
    func addTimelineMarker(frame: Int, label: String? = nil, color: String? = nil) -> TimelineMarker {
        addTimelineMarkers([TimelineMarkerDraft(frame: frame, label: label, color: color)]).first!
    }

    @discardableResult
    func addTimelineMarkers(_ drafts: [TimelineMarkerDraft]) -> [TimelineMarker] {
        var added: [TimelineMarker] = []
        withTimelineSwap(actionName: drafts.count == 1 ? "Add Marker" : "Add Markers") {
            for draft in drafts {
                let trimmedLabel = normalizedMarkerLabel(draft.label)
                let marker = TimelineMarker(
                    frame: max(0, draft.frame),
                    label: (trimmedLabel?.isEmpty == false) ? trimmedLabel! : nextTimelineMarkerLabel(),
                    color: normalizedMarkerColor(draft.color)
                )
                timeline.markers.append(marker)
                added.append(marker)
            }
            sortTimelineMarkers()
        }
        return added
    }

    func updateTimelineMarker(id: String, frame: Int? = nil, label: String? = nil, color: String? = nil) {
        updateTimelineMarkers(ids: [id], frame: frame, label: label, color: color)
    }

    @discardableResult
    func updateTimelineMarkers(ids: Set<String>, frame: Int? = nil, label: String? = nil, color: String? = nil) -> [TimelineMarker] {
        guard !ids.isEmpty, timeline.markers.contains(where: { ids.contains($0.id) }) else { return [] }
        var updated: [TimelineMarker] = []
        withTimelineSwap(actionName: "Change Marker") {
            for idx in timeline.markers.indices where ids.contains(timeline.markers[idx].id) {
                if let frame { timeline.markers[idx].frame = max(0, frame) }
                if let label { timeline.markers[idx].label = normalizedMarkerLabel(label) ?? "" }
                if let color { timeline.markers[idx].color = normalizedMarkerColor(color) }
                updated.append(timeline.markers[idx])
            }
            sortTimelineMarkers()
        }
        return updated.sorted { $0.frame == $1.frame ? $0.label < $1.label : $0.frame < $1.frame }
    }

    func removeTimelineMarkers(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        withTimelineSwap(actionName: ids.count == 1 ? "Delete Marker" : "Delete Markers") {
            timeline.markers.removeAll { ids.contains($0.id) }
        }
    }

    func timelineMarker(id: String) -> TimelineMarker? {
        timeline.markers.first { $0.id == id }
    }

    func timelineMarkers(matchingLabel label: String) -> [TimelineMarker] {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return timeline.markers.filter { $0.label.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    func markerDisplayLabel(_ marker: TimelineMarker) -> String {
        marker.label.isEmpty ? "Marker" : marker.label
    }

    private func nextTimelineMarkerLabel() -> String {
        let used = Set(timeline.markers.map(\.label))
        var index = timeline.markers.count + 1
        while used.contains("Marker \(index)") {
            index += 1
        }
        return "Marker \(index)"
    }

    private func sortTimelineMarkers() {
        timeline.markers.sort {
            if $0.frame != $1.frame { return $0.frame < $1.frame }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private func normalizedMarkerLabel(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMarkerColor(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    }
}
