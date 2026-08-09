struct AgentActivityHighlight: Equatable {
    var readClipIds: Set<String> = []
    var addedClipIds: Set<String> = []
    var mutatedClipIds: Set<String> = []
    var mutatedTrackIds: Set<String> = []
    var range: Range<Int>?
    var isActive = false
    var revision = 0

    var isRead: Bool {
        !readClipIds.isEmpty || range != nil
    }

    var isEmpty: Bool {
        !isRead && addedClipIds.isEmpty && mutatedClipIds.isEmpty && mutatedTrackIds.isEmpty
    }
}

extension EditorViewModel {
    func showAgentChanges(
        addedClipIds: Set<String>,
        mutatedClipIds: Set<String>,
        mutatedTrackIds: Set<String> = []
    ) {
        guard !addedClipIds.isEmpty || !mutatedClipIds.isEmpty || !mutatedTrackIds.isEmpty else {
            return
        }
        var activity = agentActivity.isRead
            ? AgentActivityHighlight(revision: agentActivity.revision)
            : agentActivity
        activity.addedClipIds.formUnion(addedClipIds)
        activity.mutatedClipIds.formUnion(mutatedClipIds)
        activity.mutatedTrackIds.formUnion(mutatedTrackIds)
        activity.mutatedClipIds.subtract(activity.addedClipIds)
        activity.isActive = false
        activity.revision &+= 1
        agentActivity = activity
        scheduleAgentActivityClear(after: AppTheme.Anim.agentChangeHighlightDuration)
    }

    func beginAgentTimelineRead(_ highlight: AgentActivityHighlight?) -> Int? {
        guard var highlight, highlight.isRead else { return nil }
        guard agentActivity.isEmpty || agentActivity.isRead else { return nil }
        agentActivityClearTask?.cancel()
        agentActivityClearTask = nil
        highlight.isActive = true
        highlight.revision = agentActivity.revision &+ 1
        agentActivity = highlight
        return highlight.revision
    }

    func endAgentTimelineRead(_ revision: Int, succeeded: Bool) {
        guard revision == agentActivity.revision, agentActivity.isRead, agentActivity.isActive else {
            return
        }
        guard succeeded else {
            clearAgentActivity()
            return
        }
        agentActivity.isActive = false
        agentActivity.revision &+= 1
        scheduleAgentActivityClear(after: AppTheme.Anim.agentReadHighlightDuration)
    }

    func clearAgentActivity() {
        guard !agentActivity.isEmpty || agentActivityClearTask != nil else { return }
        agentActivityClearTask?.cancel()
        agentActivityClearTask = nil
        agentActivity = AgentActivityHighlight(revision: agentActivity.revision &+ 1)
    }

    private func scheduleAgentActivityClear(after duration: Double) {
        let revision = agentActivity.revision
        agentActivityClearTask?.cancel()
        agentActivityClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self,
                  !Task.isCancelled,
                  self.agentActivity.revision == revision else { return }
            self.clearAgentActivity()
        }
    }
}
