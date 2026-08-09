private struct AgentLocatedClip: Equatable {
    let trackId: String
    let clip: Clip
}

extension ToolName {
    private static let timelineChangePublishers: Set<ToolName> = [
        .setProjectSettings,
        .manageClipLinks,
        .addClips, .insertClips, .moveClips, .removeClips,
        .splitClips, .rippleDeleteRanges, .swapClipMedia,
        .setClipProperties, .setKeyframes, .applyLayout, .syncClips, .undo,
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
        editor.showAgentChanges(
            addedClipIds: addedClipIds,
            mutatedClipIds: mutatedClipIds
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
}

// MARK: - Read highlights

extension ToolExecutor {
    func timelineReadActivity(
        for tool: ToolName,
        args: [String: Any],
        editor: EditorViewModel
    ) throws -> AgentActivityHighlight? {
        var readClipIds = Set<String>()
        var range: Range<Int>?
        switch tool {
        case .inspectMedia, .inspectColor:
            if let clipId = args.string("clipId") { readClipIds.insert(clipId) }
        case .getTranscript, .getMulticam:
            if let clipId = args.string("clipId") { readClipIds.insert(clipId) }
            range = try timelineReadWindow(args, editor: editor)
        case .inspectTimeline:
            let start = max(0, args.int("startFrame") ?? 0)
            if start < Int.max {
                let end = args.int("endFrame").flatMap { $0 > start ? $0 : nil } ?? start + 1
                range = clampedTimelineReadRange(start: start, end: end, editor: editor)
            }
        case .getTimeline:
            range = try timelineReadWindow(args, editor: editor)
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
    ) throws -> Range<Int>? {
        guard let window = try Self.frameWindow(args) else { return nil }
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
