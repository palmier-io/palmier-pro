import Foundation

/// Nested timelines: eligibility, carrier insertion, and decompose.
extension EditorViewModel {

    func wouldCreateNestCycle(nesting childId: String, into hostId: String) -> Bool {
        if childId == hostId { return true }
        guard let child = timeline(for: childId) else { return false }
        return child.reachableTimelines(resolve: timeline(for:)).contains { $0.id == hostId }
    }

    func isVisibleFromActive(_ id: String) -> Bool {
        id == activeTimelineId
            || timeline.reachableTimelines(resolve: timeline(for:)).contains { $0.id == id }
    }

    /// Why `childId` can't nest into the active timeline, or nil if it can.
    func nestBlockReason(childId: String) -> String? {
        guard let child = timeline(for: childId) else { return nil }
        if child.totalFrames == 0 {
            return "\"\(child.name)\" is empty. Add clips before nesting it."
        }
        if wouldCreateNestCycle(nesting: childId, into: activeTimelineId) {
            return "Can't nest \"\(child.name)\" — it would contain itself."
        }
        return nil
    }

    /// Drops `childId` into the active timeline as a single nested clip.
    @discardableResult
    func nestTimeline(_ childId: String, cursor: TrackDropTarget, atFrame frame: Int) -> Bool {
        guard let child = timeline(for: childId) else { return false }
        if let reason = nestBlockReason(childId: childId) {
            mediaPanelToast = MediaPanelToast(message: reason)
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
            let audioIdx = child.hasAudioClips ? resolveOrCreateAudioTrack(startFrame: startFrame, duration: duration) : nil
            insertNestCarriers(for: child, start: startFrame, duration: duration, videoIdx: videoIdx, audioIdx: audioIdx)
        }
        return true
    }

    func nestSelectedClips() {
        let ids = selectedClipIds
        var lanes: [(index: Int, type: ClipType, clips: [Clip])] = []
        for (i, track) in timeline.tracks.enumerated() {
            let picked = track.clips.filter { ids.contains($0.id) }
            if !picked.isEmpty { lanes.append((i, track.type, picked)) }
        }
        guard !lanes.isEmpty else { return }

        let all = lanes.flatMap(\.clips)
        let start = all.map(\.startFrame).min()!
        let duration = all.map(\.endFrame).max()! - start

        var child = Timeline(name: uniqueName({ "Nest \($0)" }, startingAt: 1))
        child.fps = timeline.fps
        child.width = timeline.width
        child.height = timeline.height
        child.settingsConfigured = timeline.settingsConfigured
        child.tracks = lanes.map { lane in
            Track(type: lane.type, clips: lane.clips.map { clip in
                var c = clip
                c.startFrame -= start
                return c
            })
        }
        child.regenerateIds()

        timelines.append(child)
        registerRemoveUndo(for: child.id, actionName: "Nest Clips")
        selectedClipIds = []
        withTimelineSwap(actionName: "Nest Clips") {
            for i in timeline.tracks.indices {
                timeline.tracks[i].clips.removeAll { ids.contains($0.id) }
            }
            let span = start..<(start + duration)
            var videoIdx = lanes.first { $0.type != .audio }?.index
            var audioIdx = lanes.first { $0.type == .audio }?.index
            if let vi = videoIdx, trackOverlaps(vi, span: span) {
                let inserted = insertTrack(at: vi, type: .video)
                videoIdx = inserted
                if let ai = audioIdx, ai >= inserted { audioIdx = ai + 1 }
            }
            if let ai = audioIdx, trackOverlaps(ai, span: span) {
                audioIdx = insertTrack(at: ai + 1, type: .audio)
            }
            let carriers = insertNestCarriers(
                for: child, start: start, duration: duration,
                videoIdx: videoIdx, audioIdx: audioIdx
            )
            pruneEmptyTracks()
            selectedClipIds = carriers
        }
        openTimelineIds.append(child.id)
        timelineTabRenameRequest = child.id
    }

    /// Replaces a nest clip (and its linked audio) with the child's clips remapped in place
    func decomposeNest(clipId: String) {
        guard let loc = findClip(id: clipId) else { return }
        let clicked = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clicked.sourceClipType == .sequence, let child = timeline(for: clicked.mediaRef) else { return }

        var videoCarrier: Clip?
        var audioCarrier: Clip?
        let group = expandToLinkGroup([clicked.id])
        for id in group {
            guard let l = findClip(id: id) else { continue }
            let c = timeline.tracks[l.trackIndex].clips[l.clipIndex]
            guard c.sourceClipType == .sequence, c.mediaRef == clicked.mediaRef else { continue }
            if c.mediaType == .audio { audioCarrier = c } else { videoCarrier = c }
        }
        selectedClipIds.subtract(group)

        var groups: [String: String] = [:]
        func freshen(_ clip: Clip, volumeScale: Double = 1) -> Clip {
            var c = clip
            c.freshenIds(groups: &groups)
            c.volume *= volumeScale
            return c
        }

        // Top lane reuses the carrier's track; later lanes reuse free-span tracks below before inserting new ones.
        func place(lanes: [[Clip]], carrier: Clip, type: ClipType, volumeScale: Double) {
            guard let l = findClip(id: carrier.id) else { return }
            let span = carrier.startFrame..<carrier.endFrame
            timeline.tracks[l.trackIndex].clips.remove(at: l.clipIndex)
            var idx = l.trackIndex
            for lane in lanes {
                let free = timeline.tracks.indices.contains(idx)
                    && timeline.tracks[idx].type == type
                    && !timeline.tracks[idx].clips.contains { $0.startFrame < span.upperBound && $0.endFrame > span.lowerBound }
                if !free { idx = insertTrack(at: idx, type: type) }
                timeline.tracks[idx].clips.append(contentsOf: lane.map { freshen($0, volumeScale: volumeScale) })
                sortClips(trackIndex: idx)
                idx += 1
            }
        }

        withTimelineSwap(actionName: "Decompose Nested Timeline") {
            if let carrier = videoCarrier {
                let lanes = NestFlattener.flatten(carrier: carrier, child: child, visual: true).videoTracks
                place(lanes: lanes, carrier: carrier, type: .video, volumeScale: 1)
            }
            if let carrier = audioCarrier {
                let lanes = NestFlattener.flatten(carrier: carrier, child: child, visual: false).audioTracks
                place(lanes: lanes, carrier: carrier, type: .audio, volumeScale: carrier.volume)
            }
            pruneEmptyTracks()
        }

        if videoCarrier.map({ carrierHasGroupLook($0, child: child) }) == true
            || audioCarrier.map({ $0.fadeInFrames > 0 || $0.fadeOutFrames > 0 || $0.volumeTrack != nil }) == true {
            mediaPanelToast = "Nest settings discarded. Undo to restore."
        }
    }

    private func trackOverlaps(_ idx: Int, span: Range<Int>) -> Bool {
        timeline.tracks[idx].clips.contains { $0.startFrame < span.upperBound && $0.endFrame > span.lowerBound }
    }

    /// Group-level looks that have no per-clip equivalent after decompose.
    private func carrierHasGroupLook(_ clip: Clip, child: Timeline) -> Bool {
        clip.opacity != 1 || clip.crop != Crop() || clip.effects?.isEmpty == false
            || clip.fadeInFrames > 0 || clip.fadeOutFrames > 0 || clip.blendMode != nil
            || clip.opacityTrack != nil || clip.positionTrack != nil || clip.scaleTrack != nil
            || clip.rotationTrack != nil || clip.cropTrack != nil
            || clip.transform != fitTransform(sourceWidth: child.width, sourceHeight: child.height)
    }

    /// Inserts linked `.sequence` carrier clips on already-resolved tracks, clearing their span.
    @discardableResult
    private func insertNestCarriers(for child: Timeline, start: Int, duration: Int, videoIdx: Int?, audioIdx: Int?) -> Set<String> {
        let linkGroupId = videoIdx != nil && audioIdx != nil ? UUID().uuidString : nil
        var carrierIds: Set<String> = []
        if let vi = videoIdx {
            clearRegion(trackIndex: vi, start: start, end: start + duration, prune: false)
            var clip = Clip(
                mediaRef: child.id,
                mediaType: .sequence,
                sourceClipType: .sequence,
                startFrame: start,
                durationFrames: duration,
                transform: fitTransform(sourceWidth: child.width, sourceHeight: child.height)
            )
            clip.linkGroupId = linkGroupId
            timeline.tracks[vi].clips.append(clip)
            sortClips(trackIndex: vi)
            carrierIds.insert(clip.id)
        }
        if let ai = audioIdx {
            clearRegion(trackIndex: ai, start: start, end: start + duration, prune: false)
            var clip = Clip(
                mediaRef: child.id,
                mediaType: .audio,
                sourceClipType: .sequence,
                startFrame: start,
                durationFrames: duration
            )
            clip.linkGroupId = linkGroupId
            timeline.tracks[ai].clips.append(clip)
            sortClips(trackIndex: ai)
            carrierIds.insert(clip.id)
        }
        return carrierIds
    }
}
