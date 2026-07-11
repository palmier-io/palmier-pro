import Foundation

/// Multiple timelines per project: switching, per-timeline view state, and CRUD.
extension EditorViewModel {

    func timeline(for id: String) -> Timeline? {
        timelines.first { $0.id == id }
    }

    /// Sendable snapshot for render/export paths that resolve nested timelines off-main.
    func timelineResolver() -> @Sendable (String) -> Timeline? {
        let byId = Dictionary(uniqueKeysWithValues: timelines.map { ($0.id, $0) })
        return { byId[$0] }
    }

    func applyProjectFile(_ file: ProjectFile) {
        guard !file.timelines.isEmpty else { return }
        timelines = file.timelines
        liveViewStates = file.viewStates ?? [:]
        let ids = Set(file.timelines.map(\.id))
        activeTimelineId = file.activeTimelineId.flatMap { ids.contains($0) ? $0 : nil }
            ?? file.timelines[0].id
        openTimelineIds = (file.openTimelineIds ?? []).filter { ids.contains($0) }
        speakerRegistry = file.speakers ?? []
        multicamGroups = file.multicamGroups ?? []
        syncSpeakerColors()
        if !openTimelineIds.contains(activeTimelineId) {
            openTimelineIds.append(activeTimelineId)
        }
        restoreActiveViewState()
    }

    /// Snapshot for save/export; view states pruned to timelines that still exist.
    func projectFileSnapshot() -> ProjectFile {
        stashActiveViewState()
        let ids = Set(timelines.map(\.id))
        return ProjectFile(
            timelines: timelines,
            activeTimelineId: activeTimelineId,
            openTimelineIds: openTimelineIds,
            viewStates: liveViewStates.filter { ids.contains($0.key) },
            speakers: speakerRegistry.isEmpty ? nil : speakerRegistry,
            multicamGroups: savedMulticamGroups()
        )
    }

    func stashActiveViewState() {
        liveViewStates[activeTimelineId] = TimelineViewState(
            playheadFrame: currentFrame,
            zoomScale: zoomScale,
            scrollOffsetX: timelineScrollOffsetX
        )
    }

    func viewState(for id: String) -> TimelineViewState {
        liveViewStates[id] ?? TimelineViewState()
    }

    func restoreActiveViewState() {
        let vs = viewState(for: activeTimelineId)
        zoomScale = vs.zoomScale
        currentFrame = min(max(0, vs.playheadFrame), max(0, timeline.totalFrames))
        timelineScrollRestoreX = vs.scrollOffsetX
    }

    func activateTimeline(_ id: String) {
        guard id != activeTimelineId, timelines.contains(where: { $0.id == id }) else { return }
        revertInFlightDrag()
        stashActiveViewState()
        if isPlaying { pause() }
        clearTimelineScopedState()
        activeTimelineId = id
        if !openTimelineIds.contains(id) { openTimelineIds.append(id) }
        timelineRenderRevision &+= 1
        restoreActiveViewState()
        // refreshVisuals would apply the new timeline to the old track mappings — rebuild alone is correct.
        notifyTimelineChanged(refreshVisuals: false)
        seekToFrame(currentFrame)
    }

    /// A switch mid-gesture would orphan live mutations with no undo — put the clips back first.
    private func revertInFlightDrag() {
        if let preDrag = preDragTimeline {
            timeline = preDrag
        } else {
            for (id, before) in dragBefore {
                guard let loc = findClip(id: id) else { continue }
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = before
            }
        }
    }

    private func clearTimelineScopedState() {
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        pendingSwapClipId = nil
        dragBefore = [:]
        preDragTimeline = nil
    }

    /// registerUndo that re-activates the owning timeline before applying.
    func registerTimelineUndo(_ handler: @escaping @MainActor (EditorViewModel) -> Void) {
        let tid = activeTimelineId
        undoManager?.registerUndo(withTarget: self) { vm in
            if vm.activeTimelineId != tid, vm.timelines.contains(where: { $0.id == tid }) {
                vm.activateTimeline(tid)
            }
            handler(vm)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func createTimeline(name: String? = nil, activate: Bool = true) -> String {
        let active = timeline
        var t = Timeline(name: name ?? nextTimelineName())
        t.fps = active.fps
        t.width = active.width
        t.height = active.height
        t.settingsConfigured = active.settingsConfigured
        timelines.append(t)
        registerRemoveUndo(for: t.id, actionName: "New Timeline")
        if activate { activateTimeline(t.id) }
        return t.id
    }

    @discardableResult
    func duplicateTimeline(_ id: String, activate: Bool = true) -> String? {
        guard var copy = timeline(for: id) else { return nil }
        copy.id = UUID().uuidString
        copy.name = duplicateName(for: copy.name)
        copy.regenerateIds()
        timelines.append(copy)
        stashActiveViewState()
        liveViewStates[copy.id] = viewState(for: id)
        registerRemoveUndo(for: copy.id, actionName: "Duplicate Timeline")
        if activate { activateTimeline(copy.id) }
        return copy.id
    }

    func renameTimeline(_ id: String, to name: String) {
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, timelines[i].name != trimmed else { return }
        let previous = timelines[i].name
        timelines[i].name = trimmed
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameTimeline(id, to: previous)
        }
        undoManager?.setActionName("Rename Timeline")
    }

    func deleteTimeline(_ id: String) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        guard timelines.count > 1 else {
            mediaPanelToast = "Can't delete every timeline — the project needs at least one."
            return
        }
        let openIndex = openTimelineIds.firstIndex(of: id)
        let wasActive = activeTimelineId == id
        if wasActive {
            let fallback = openTimelineIds.first { $0 != id }
                ?? timelines.first { $0.id != id }!.id
            activateTimeline(fallback)
        }
        let removed = timelines[index]
        let removedViewState = viewState(for: id)
        let wasNestedInActive = isVisibleFromActive(id)
        timelines.remove(at: index)
        liveViewStates.removeValue(forKey: id)
        selectedTimelineIds.remove(id)
        videoEngine?.evictComposition(for: id)
        if let openIndex { openTimelineIds.remove(at: openIndex) }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.reinsertTimeline(removed, viewState: removedViewState, at: index, openAt: openIndex, reactivate: wasActive)
        }
        undoManager?.setActionName("Delete Timeline")
        if wasNestedInActive {
            notifyTimelineChanged(refreshVisuals: false)
        }
    }

    func closeTimelineTab(_ id: String) {
        guard openTimelineIds.count > 1,
              let index = openTimelineIds.firstIndex(of: id) else { return }
        if activeTimelineId == id {
            activateTimeline(openTimelineIds[index == 0 ? 1 : index - 1])
        }
        openTimelineIds.remove(at: index)
        videoEngine?.evictComposition(for: id)
    }

    func closeOtherTimelineTabs(keeping id: String) {
        guard openTimelineIds.contains(id) else { return }
        activateTimeline(id)
        for closed in openTimelineIds where closed != id {
            videoEngine?.evictComposition(for: closed)
        }
        openTimelineIds = [id]
    }

    private func reinsertTimeline(_ t: Timeline, viewState: TimelineViewState, at index: Int, openAt openIndex: Int?, reactivate: Bool) {
        timelines.insert(t, at: min(index, timelines.count))
        liveViewStates[t.id] = viewState
        if let openIndex {
            openTimelineIds.insert(t.id, at: min(openIndex, openTimelineIds.count))
        }
        if reactivate {
            activateTimeline(t.id)
        } else if isVisibleFromActive(t.id) {
            notifyTimelineChanged(refreshVisuals: false)
        }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.deleteTimeline(t.id)
        }
    }

    func registerRemoveUndo(for id: String, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.deleteTimeline(id)
        }
        undoManager?.setActionName(actionName)
    }

    /// Removes every clip referencing `assetIds` from every timeline; prunes emptied tracks.
    @discardableResult
    func removeClipsReferencingAssets(_ assetIds: Set<String>) -> Set<String> {
        var removed: Set<String> = []
        for i in timelines.indices {
            var touched = false
            for t in timelines[i].tracks.indices {
                let hits = timelines[i].tracks[t].clips.filter { assetIds.contains($0.mediaRef) }
                guard !hits.isEmpty else { continue }
                removed.formUnion(hits.map(\.id))
                timelines[i].tracks[t].clips.removeAll { assetIds.contains($0.mediaRef) }
                touched = true
            }
            if touched { timelines[i].tracks.removeAll(where: \.clips.isEmpty) }
        }
        selectedClipIds.subtract(removed)
        return removed
    }

    // MARK: - Naming

    func nextTimelineName() -> String {
        uniqueName({ "Timeline \($0)" }, startingAt: timelines.count + 1)
    }

    private func duplicateName(for name: String) -> String {
        uniqueName({ $0 == 1 ? "\(name) copy" : "\(name) copy \($0)" }, startingAt: 1)
    }

    func uniqueName(_ candidate: (Int) -> String, startingAt start: Int) -> String {
        let used = Set(timelines.map(\.name))
        var n = start
        while used.contains(candidate(n)) { n += 1 }
        return candidate(n)
    }
}

extension Timeline {
    /// Fresh track/clip/group ids for a duplicated timeline so ids stay unique project-wide.
    mutating func regenerateIds() {
        var groups: [String: String] = [:]
        for ti in tracks.indices {
            tracks[ti].id = UUID().uuidString
            for ci in tracks[ti].clips.indices {
                tracks[ti].clips[ci].freshenIds(groups: &groups)
            }
        }
    }
}
