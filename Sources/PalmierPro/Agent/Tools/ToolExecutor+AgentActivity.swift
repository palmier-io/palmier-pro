private struct AgentLocatedClip: Equatable {
    let trackId: String
    let clip: Clip
}

extension ToolName {
    private static let timelineChangePublishers: Set<ToolName> = [
        .setProjectSettings,
        .manageTracks,
        .manageClipLinks,
        .addClips, .insertClips, .moveClips, .removeClips,
        .splitClips, .rippleDeleteRanges, .swapClipMedia,
        .setClipProperties, .copyClipSettings, .setKeyframes, .applyLayout, .syncClips, .undo,
        .manageMulticam, .changeCam,
        .removeWords, .removeSilence,
        .addTexts, .updateText, .addCaptions,
        .applyColor, .applyEffect, .denoiseAudio,
        .generateAudio,
    ]

    var publishesTimelineChanges: Bool {
        Self.timelineChangePublishers.contains(self)
    }
}

// MARK: - Change highlights

extension ToolExecutor {
    func publishAgentChanges(
        before: Timeline,
        after: Timeline,
        editor: EditorViewModel
    ) {
        let beforeClips = locatedClips(in: before)
        let afterClips = locatedClips(in: after)
        let addedClipIds = Set(afterClips.keys).subtracting(beforeClips.keys)
        let mutatedClipIds = Set<String>(beforeClips.compactMap { id, previous in
            guard let current = afterClips[id], current != previous else { return nil }
            return id
        })
        let mutatedTrackIds = changedTrackIds(before: before, after: after)
        editor.showAgentChanges(
            addedClipIds: addedClipIds,
            mutatedClipIds: mutatedClipIds,
            mutatedTrackIds: mutatedTrackIds
        )
    }

    private func locatedClips(in timeline: Timeline) -> [String: AgentLocatedClip] {
        var result: [String: AgentLocatedClip] = [:]
        for track in timeline.tracks {
            for clip in track.clips {
                result[clip.id] = AgentLocatedClip(trackId: track.id, clip: clip)
            }
        }
        return result
    }

    private func changedTrackIds(before: Timeline, after: Timeline) -> Set<String> {
        let beforeTracks = Dictionary(
            before.tracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let afterTracks = Dictionary(
            after.tracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let survivingIds = Set(beforeTracks.keys).intersection(afterTracks.keys)
        var changed = Set(survivingIds.filter { id in
            guard let previous = beforeTracks[id], let current = afterTracks[id] else { return false }
            return previous.muted != current.muted
                || previous.hidden != current.hidden
                || previous.syncLocked != current.syncLocked
        })

        // Ignore index shifts caused only by insertion or removal.
        let beforeOrder = before.tracks.map(\.id).filter(survivingIds.contains)
        let afterOrder = after.tracks.map(\.id).filter(survivingIds.contains)
        changed.formUnion(zip(beforeOrder, afterOrder).compactMap { previous, current in
            previous == current ? nil : current
        })
        return changed
    }
}

// MARK: - Read highlights

extension ToolExecutor {
    func timelineReadActivity(
        for tool: ToolName,
        args: [String: Any],
        editor: EditorViewModel
    ) -> AgentActivityHighlight? {
        var readClipIds = Set<String>()
        var range: Range<Int>?
        switch tool {
        case .inspectMedia, .inspectColor:
            if let clipId = args.string("clipId") { readClipIds.insert(clipId) }
        case .getTranscript, .getMulticam:
            if let clipId = args.string("clipId") { readClipIds.insert(clipId) }
            range = timelineReadWindow(args, editor: editor)
        case .inspectTimeline:
            let start = max(0, args.int("startFrame") ?? 0)
            if start < Int.max {
                let end = args.int("endFrame").flatMap { $0 > start ? $0 : nil } ?? start + 1
                range = clampedTimelineReadRange(start: start, end: end, editor: editor)
            }
        case .getTimeline:
            range = timelineReadWindow(args, editor: editor)
        case .captureFrame:
            if let frame = args.int("timelineFrame"), frame >= 0, frame < Int.max {
                range = clampedTimelineReadRange(start: frame, end: frame + 1, editor: editor)
            }
        default:
            return nil
        }

        readClipIds = Set(readClipIds.filter { editor.findClip(id: $0) != nil })
        guard !readClipIds.isEmpty || range != nil else { return nil }
        return AgentActivityHighlight(readClipIds: readClipIds, range: range)
    }

    private func timelineReadWindow(
        _ args: [String: Any],
        editor: EditorViewModel
    ) -> Range<Int>? {
        let window: Range<Int>?
        do {
            window = try Self.frameWindow(args)
        } catch {
            return nil
        }
        guard let window else { return nil }
        let end = window.upperBound == Int.max ? editor.timeline.totalFrames : window.upperBound
        return clampedTimelineReadRange(start: window.lowerBound, end: end, editor: editor)
    }

    private func clampedTimelineReadRange(
        start: Int,
        end: Int,
        editor: EditorViewModel
    ) -> Range<Int>? {
        let lower = max(0, start)
        let upper = min(editor.timeline.totalFrames, end)
        guard lower < upper else { return nil }
        return lower..<upper
    }
}
