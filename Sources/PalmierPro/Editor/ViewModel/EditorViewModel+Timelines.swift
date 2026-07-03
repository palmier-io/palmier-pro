import Foundation

/// Multiple timelines per project: switching, per-timeline view state, and CRUD.
extension EditorViewModel {

    func timeline(for id: String) -> Timeline? {
        timelines.first { $0.id == id }
    }

    func applyProjectFile(_ file: ProjectFile) {
        guard !file.timelines.isEmpty else { return }
        timelines = file.timelines
        liveViewStates = Dictionary(uniqueKeysWithValues: file.timelines.map { ($0.id, $0.viewState) })
        let ids = Set(file.timelines.map(\.id))
        activeTimelineId = file.activeTimelineId.flatMap { ids.contains($0) ? $0 : nil }
            ?? file.timelines[0].id
        openTimelineIds = (file.openTimelineIds ?? []).filter { ids.contains($0) }
        if !openTimelineIds.contains(activeTimelineId) {
            openTimelineIds.append(activeTimelineId)
        }
        restoreActiveViewState()
    }

    /// Snapshot for save/export: timelines with live view state merged in.
    func projectFileSnapshot() -> ProjectFile {
        stashActiveViewState()
        var merged = timelines
        for i in merged.indices {
            if let vs = liveViewStates[merged[i].id] { merged[i].viewState = vs }
        }
        return ProjectFile(timelines: merged, activeTimelineId: activeTimelineId, openTimelineIds: openTimelineIds)
    }

    func stashActiveViewState() {
        liveViewStates[activeTimelineId] = TimelineViewState(
            playheadFrame: currentFrame,
            zoomScale: zoomScale,
            scrollOffsetX: timelineScrollOffsetX
        )
    }

    func viewState(for id: String) -> TimelineViewState {
        liveViewStates[id] ?? timeline(for: id)?.viewState ?? TimelineViewState()
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
        restoreActiveViewState()
        notifyTimelineChanged()
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
        copy.viewState = viewState(for: id)
        copy.regenerateIds()
        timelines.append(copy)
        liveViewStates[copy.id] = copy.viewState
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
        guard timelines.count > 1,
              let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        let openIndex = openTimelineIds.firstIndex(of: id)
        let wasActive = activeTimelineId == id
        if wasActive {
            let fallback = openTimelineIds.first { $0 != id }
                ?? timelines.first { $0.id != id }!.id
            activateTimeline(fallback)
        }
        var removed = timelines[index]
        removed.viewState = viewState(for: id)
        timelines.remove(at: index)
        if let openIndex { openTimelineIds.remove(at: openIndex) }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.reinsertTimeline(removed, at: index, openAt: openIndex, reactivate: wasActive)
        }
        undoManager?.setActionName("Delete Timeline")
    }

    func closeTimelineTab(_ id: String) {
        guard openTimelineIds.count > 1,
              let index = openTimelineIds.firstIndex(of: id) else { return }
        if activeTimelineId == id {
            activateTimeline(openTimelineIds[index == 0 ? 1 : index - 1])
        }
        openTimelineIds.remove(at: index)
    }

    func closeOtherTimelineTabs(keeping id: String) {
        guard openTimelineIds.contains(id) else { return }
        activateTimeline(id)
        openTimelineIds = [id]
    }

    private func reinsertTimeline(_ t: Timeline, at index: Int, openAt openIndex: Int?, reactivate: Bool) {
        timelines.insert(t, at: min(index, timelines.count))
        liveViewStates[t.id] = t.viewState
        if let openIndex {
            openTimelineIds.insert(t.id, at: min(openIndex, openTimelineIds.count))
        }
        if reactivate { activateTimeline(t.id) }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.deleteTimeline(t.id)
        }
    }

    private func registerRemoveUndo(for id: String, actionName: String) {
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
                for clip in timelines[i].tracks[t].clips where assetIds.contains(clip.mediaRef) {
                    removed.insert(clip.id)
                    touched = true
                }
                if touched {
                    timelines[i].tracks[t].clips.removeAll { assetIds.contains($0.mediaRef) }
                }
            }
            if touched { timelines[i].tracks.removeAll(where: \.clips.isEmpty) }
        }
        selectedClipIds.subtract(removed)
        return removed
    }

    // MARK: - Nesting

    func wouldCreateNestCycle(nesting childId: String, into hostId: String) -> Bool {
        if childId == hostId { return true }
        var visited: Set<String> = []
        var frontier = [childId]
        while let current = frontier.popLast() {
            guard visited.insert(current).inserted else { continue }
            guard let t = timeline(for: current) else { continue }
            let ids = t.nestedTimelineIds
            if ids.contains(hostId) { return true }
            frontier.append(contentsOf: ids)
        }
        return false
    }

    /// Drops `childId` into the active timeline as a single nested clip.
    @discardableResult
    func nestTimeline(_ childId: String, cursor: TrackDropTarget, atFrame frame: Int) -> Bool {
        guard let child = timeline(for: childId) else { return false }
        guard child.totalFrames > 0 else {
            mediaPanelToast = "\"\(child.name)\" is empty. Add clips before nesting it."
            return false
        }
        guard !wouldCreateNestCycle(nesting: childId, into: activeTimelineId) else {
            mediaPanelToast = "Can't nest \"\(child.name)\" — it would contain itself."
            return false
        }

        let duration = child.totalFrames
        let startFrame = max(0, frame)

        withTimelineSwap(actionName: "Nest Timeline") {
            var videoTarget = cursor
            if case .existingTrack(let idx) = cursor,
               !(timeline.tracks.indices.contains(idx) && timeline.tracks[idx].type == .video) {
                videoTarget = .newTrackAt(0)
            }
            let videoIdx = materializeTrackIndex(target: videoTarget, type: .video)
            clearRegion(trackIndex: videoIdx, start: startFrame, end: startFrame + duration)

            let hasAudio = child.tracks.contains { $0.type == .audio && !$0.clips.isEmpty }
            let linkGroupId: String? = hasAudio ? UUID().uuidString : nil

            var clip = Clip(
                mediaRef: childId,
                mediaType: .sequence,
                sourceClipType: .sequence,
                startFrame: startFrame,
                durationFrames: duration,
                transform: fitTransform(sourceWidth: child.width, sourceHeight: child.height)
            )
            clip.linkGroupId = linkGroupId
            timeline.tracks[videoIdx].clips.append(clip)
            sortClips(trackIndex: videoIdx)

            if let linkGroupId {
                let audioIdx = resolveOrCreateAudioTrack(startFrame: startFrame, duration: duration)
                var audioClip = Clip(
                    mediaRef: childId,
                    mediaType: .audio,
                    sourceClipType: .sequence,
                    startFrame: startFrame,
                    durationFrames: duration
                )
                audioClip.linkGroupId = linkGroupId
                timeline.tracks[audioIdx].clips.append(audioClip)
                sortClips(trackIndex: audioIdx)
            }
        }
        return true
    }

    // MARK: - Naming

    func nextTimelineName() -> String {
        uniqueName({ "Timeline \($0)" }, startingAt: timelines.count + 1)
    }

    private func duplicateName(for name: String) -> String {
        uniqueName({ $0 == 1 ? "\(name) copy" : "\(name) copy \($0)" }, startingAt: 1)
    }

    private func uniqueName(_ candidate: (Int) -> String, startingAt start: Int) -> String {
        let used = Set(timelines.map(\.name))
        var n = start
        while used.contains(candidate(n)) { n += 1 }
        return candidate(n)
    }
}

extension Timeline {
    /// Fresh track/clip/group ids for a duplicated timeline so ids stay unique project-wide.
    mutating func regenerateIds() {
        var groupMap: [String: String] = [:]
        func remap(_ old: String?) -> String? {
            guard let old else { return nil }
            if let new = groupMap[old] { return new }
            let new = UUID().uuidString
            groupMap[old] = new
            return new
        }
        for ti in tracks.indices {
            tracks[ti].id = UUID().uuidString
            for ci in tracks[ti].clips.indices {
                tracks[ti].clips[ci].id = UUID().uuidString
                tracks[ti].clips[ci].linkGroupId = remap(tracks[ti].clips[ci].linkGroupId)
                tracks[ti].clips[ci].captionGroupId = remap(tracks[ti].clips[ci].captionGroupId)
            }
        }
    }
}
