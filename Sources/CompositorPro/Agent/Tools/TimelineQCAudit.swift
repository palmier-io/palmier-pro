import Foundation

/// A single problem found in a timeline, with enough location to act on it without re-reading.
struct TimelineIssue: Sendable, Equatable, Identifiable {
    enum Severity: String, Sendable, Equatable, CaseIterable {
        /// Will fail or visibly break the render.
        case error
        /// Legal but almost certainly not what was meant.
        case warning

        /// True when a finding at `self` is at least as serious as `threshold`.
        func meets(_ threshold: Severity) -> Bool {
            Self.allCases.firstIndex(of: self).map {
                $0 <= Self.allCases.firstIndex(of: threshold)!
            } ?? false
        }
    }

    enum Kind: String, Sendable, Equatable {
        case missingMedia
        case unprocessableMedia
        case emptyClip
        case overlappingClips
        case trackGap
        case staleTransition
        case clipFadesHard
        case inconsistentAudioLevel
        case unduckingDialogue
        case outOfRangeSource
        case hiddenTrack
        case noAudio
        case emptyTimeline
    }

    var id: String { "\(kind.rawValue)-\(clipId ?? "")-\(startFrame)-\(detail)" }
    var kind: Kind
    var severity: Severity
    /// Timeline frame the issue applies to, when it has one.
    var startFrame: Int?
    var endFrame: Int?
    var trackIndex: Int?
    var clipId: String?
    var mediaRef: String?
    /// Human-readable, machine-stable wording. Not localized: this is a tool contract.
    var detail: String
    /// The tool call that would resolve it, if there is exactly one.
    var fix: String?
}

@MainActor
enum TimelineQCAudit {
    /// A whole-timeline read-only check. Never mutates; the Agent acts on what it reports.
    ///
    /// Deliberately conservative: a finding must name something the Agent can change. Anything
    /// requiring a judgement call about intent (is this cut too fast? is this grade too flat?) is
    /// out of scope for a tool that cannot ask follow-up questions per finding.
    static func audit(
        timeline: Timeline,
        editor: EditorViewModel
    ) -> [TimelineIssue] {
        var issues: [TimelineIssue] = []
        let clips = timeline.tracks.flatMap(\.clips)
        guard !clips.isEmpty else {
            return [TimelineIssue(
                kind: .emptyTimeline, severity: .error, startFrame: nil, endFrame: nil,
                trackIndex: nil, clipId: nil, mediaRef: nil,
                detail: "The timeline has no clips. Add media with import_media, then add_clips.",
                fix: "get_timeline"
            )]
        }
        if !clips.contains(where: { $0.mediaType == .audio || $0.linkGroupId != nil }) {
            issues.append(TimelineIssue(
                kind: .noAudio, severity: .error, startFrame: nil, endFrame: nil,
                trackIndex: nil, clipId: nil, mediaRef: nil,
                detail: "No audio anywhere in the timeline.",
                fix: "import_media"
            ))
        }
        for (index, track) in timeline.tracks.enumerated() {
            let sorted = track.clips.sorted { $0.startFrame < $1.startFrame }
            for clip in sorted {
                issues.append(contentsOf: clipIssues(clip, trackIndex: index, editor: editor))
            }
            issues.append(contentsOf: overlapIssues(sorted, trackIndex: index))
            if track.type == .video || track.type == .audio {
                issues.append(contentsOf: gapIssues(sorted, trackIndex: index, durationFrames: timeline.totalFrames))
            }
            if track.hidden {
                issues.append(TimelineIssue(
                    kind: .hiddenTrack, severity: .warning, startFrame: nil, endFrame: nil,
                    trackIndex: index, clipId: nil, mediaRef: nil,
                    detail: "Track \(index) is hidden, so its clips are excluded from the render.",
                    fix: "manage_tracks"
                ))
            }
        }
        issues.append(contentsOf: transitionIssues(timeline))
        // Errors first, then by position, so the report reads top-down like the timeline.
        return issues.sorted {
            $0.severity == $1.severity
                ? ($0.startFrame ?? 0) < ($1.startFrame ?? 0)
                : $0.severity.meets(.error) && !$1.severity.meets(.error)
        }
    }

    // MARK: - Per clip

    private static func clipIssues(
        _ clip: Clip, trackIndex: Int, editor: EditorViewModel
    ) -> [TimelineIssue] {
        var issues: [TimelineIssue] = []
        let range = (clip.startFrame, clip.endFrame)
        if clip.mediaType == .video || clip.mediaType == .image || clip.mediaType == .lottie {
            if editor.missingMediaRefs.contains(clip.mediaRef) {
                issues.append(TimelineIssue(
                    kind: .missingMedia, severity: .error, startFrame: range.0, endFrame: range.1,
                    trackIndex: trackIndex, clipId: clip.id, mediaRef: clip.mediaRef,
                    detail: "Media is missing from disk. The render will skip or freeze this clip.",
                    fix: "import_media"
                ))
            } else if editor.unprocessableMediaRefs.contains(clip.mediaRef) {
                issues.append(TimelineIssue(
                    kind: .unprocessableMedia, severity: .error, startFrame: range.0, endFrame: range.1,
                    trackIndex: trackIndex, clipId: clip.id, mediaRef: clip.mediaRef,
                    detail: "Media could not be read. It is corrupt or in an unsupported format.",
                    fix: "import_media"
                ))
            }
        }
        if clip.durationFrames <= 0 {
            issues.append(TimelineIssue(
                kind: .emptyClip, severity: .error, startFrame: range.0, endFrame: range.1,
                trackIndex: trackIndex, clipId: clip.id, mediaRef: clip.mediaRef,
                detail: "Clip occupies no frames.",
                fix: "remove_clips"
            ))
        }
        // Trims must stay inside the media. A ramp can push consumption past the asset.
        if let asset = editor.mediaAssetsById[clip.mediaRef], editor.timeline.fps > 0 {
            let available = Int((asset.duration * Double(editor.timeline.fps)).rounded())
            let needed = clip.trimStartFrame + clip.sourceFramesConsumed
            if available > 0, needed > available {
                issues.append(TimelineIssue(
                    kind: .outOfRangeSource, severity: .error, startFrame: range.0, endFrame: range.1,
                    trackIndex: trackIndex, clipId: clip.id, mediaRef: clip.mediaRef,
                    detail: "Reads \(needed) source frames but the media only has \(available). "
                        + "The tail will run past the end.",
                    fix: "set_clip_properties"
                ))
            }
        }
        // An audio clip that starts and ends at full level clicks against its neighbours.
        if clip.mediaType == .audio, clip.fadeInFrames == 0, clip.fadeOutFrames == 0,
           clip.volumeTrack?.isActive != true {
            issues.append(TimelineIssue(
                kind: .clipFadesHard, severity: .warning, startFrame: range.0, endFrame: range.1,
                trackIndex: trackIndex, clipId: clip.id, mediaRef: clip.mediaRef,
                detail: "Audio clip has no fade in or out.",
                fix: "crossfade_audio"
            ))
        }
        return issues
    }

    // MARK: - Track layout

    private static func overlapIssues(_ sorted: [Clip], trackIndex: Int) -> [TimelineIssue] {
        var issues: [TimelineIssue] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.startFrame < a.endFrame {
            issues.append(TimelineIssue(
                kind: .overlappingClips, severity: .error,
                startFrame: b.startFrame, endFrame: a.endFrame,
                trackIndex: trackIndex, clipId: b.id, mediaRef: b.mediaRef,
                detail: "Overlaps the previous clip by \(a.endFrame - b.startFrame) frames "
                    + "on the same track.",
                fix: "get_timeline"
            ))
        }
        return issues
    }

    private static func gapIssues(
        _ sorted: [Clip], trackIndex: Int, durationFrames: Int
    ) -> [TimelineIssue] {
        var issues: [TimelineIssue] = []
        var cursor = 0
        for clip in sorted {
            if clip.startFrame > cursor {
                issues.append(TimelineIssue(
                    kind: .trackGap, severity: .warning,
                    startFrame: cursor, endFrame: clip.startFrame,
                    trackIndex: trackIndex, clipId: nil, mediaRef: nil,
                    detail: "\(clip.startFrame - cursor) empty frames at the head of this track.",
                    fix: "get_timeline"
                ))
            }
            cursor = max(cursor, clip.endFrame)
        }
        if durationFrames > 0, cursor < durationFrames {
            issues.append(TimelineIssue(
                kind: .trackGap, severity: .warning,
                startFrame: cursor, endFrame: durationFrames,
                trackIndex: trackIndex, clipId: nil, mediaRef: nil,
                detail: "\(durationFrames - cursor) empty frames at the tail of this track.",
                fix: "get_timeline"
            ))
        }
        return issues
    }

    // MARK: - Transitions

    private static func transitionIssues(_ timeline: Timeline) -> [TimelineIssue] {
        timeline.transitions.compactMap { record in
            guard record.boundary(in: timeline) == nil else { return nil }
            return TimelineIssue(
                kind: .staleTransition, severity: .error, startFrame: nil, endFrame: nil,
                trackIndex: nil, clipId: record.id, mediaRef: nil,
                detail: "Transition references clips that are gone or no longer adjacent.",
                fix: "remove_transition"
            )
        }
    }
}
