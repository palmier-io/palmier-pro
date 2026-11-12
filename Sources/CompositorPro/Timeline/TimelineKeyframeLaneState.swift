import Foundation

@MainActor
final class TimelineKeyframeLaneState {
    private(set) var expandedTrackIds: Set<String> = []
    private(set) var revision = 0
    var onChange: (() -> Void)?
    private var timelineId: String?
    private var eligibilityRevision: Int?

    func isExpanded(trackId: String) -> Bool {
        expandedTrackIds.contains(trackId)
    }

    func update(timelineId: String, revision: Int, tracks: [Track]) {
        guard self.timelineId == timelineId else {
            self.timelineId = timelineId
            eligibilityRevision = revision
            reset()
            return
        }
        guard eligibilityRevision != revision else { return }
        eligibilityRevision = revision
        prune(validTrackIds: Set(tracks.compactMap {
            AnimatableProperty.lanes(for: $0).isEmpty ? nil : $0.id
        }))
    }

    func toggle(trackId: String) {
        if expandedTrackIds.remove(trackId) == nil {
            expandedTrackIds.insert(trackId)
        }
        notifyChange()
    }

    func prune(validTrackIds: Set<String>) {
        let next = expandedTrackIds.intersection(validTrackIds)
        guard next != expandedTrackIds else { return }
        expandedTrackIds = next
        notifyChange()
    }

    func reset() {
        guard !expandedTrackIds.isEmpty else { return }
        expandedTrackIds.removeAll()
        notifyChange()
    }

    private func notifyChange() {
        revision &+= 1
        onChange?()
    }
}
