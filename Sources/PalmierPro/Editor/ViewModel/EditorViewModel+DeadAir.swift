import AppKit

enum DeadAirMaskResolver {
    static func mask(
        for clip: Clip,
        in group: MulticamSource,
        settings: SilenceRemovalSettings,
        quietMaskForMedia: (String) -> [Bool]?
    ) -> [Bool]? {
        guard let member = group.member(mediaRef: clip.mediaRef),
              clip.mediaType == .audio else { return nil }

        let microphones = group.mics
        guard !microphones.isEmpty else { return nil }
        let cellSeconds = VoiceActivity.chunkDuration
        var alignedMasks: [(values: [Bool], offset: Int)] = []
        alignedMasks.reserveCapacity(microphones.count)
        for microphone in microphones {
            guard let values = quietMaskForMedia(microphone.mediaRef),
                  !values.isEmpty else { return nil }
            let offset = Int((microphone.sync.offsetSeconds / cellSeconds).rounded())
            alignedMasks.append((values, offset))
        }

        let count = alignedMasks.reduce(0) { max($0, $1.values.count + $1.offset) }
        var groupMask = [Bool](repeating: true, count: count)
        for i in 0..<count {
            for mask in alignedMasks {
                let sourceIndex = i - mask.offset
                if mask.values.indices.contains(sourceIndex), !mask.values[sourceIndex] {
                    groupMask[i] = false
                    break
                }
            }
        }

        let shift = Int((member.sync.offsetSeconds / cellSeconds).rounded())
        let memberMask: [Bool]
        if shift > 0 {
            memberMask = Array(groupMask.dropFirst(shift))
        } else if shift < 0 {
            memberMask = [Bool](repeating: false, count: -shift) + groupMask
        } else {
            memberMask = groupMask
        }
        return SilenceRemovalPlanner.removableMask(from: memberMask, settings: settings)
    }
}

@MainActor
final class DeadAirMaskCache {
    struct Key: Hashable {
        struct Member: Hashable {
            let id: String
            let mediaRef: String
            let offsetSeconds: Double

            init(_ member: MulticamSource.Member) {
                id = member.id
                mediaRef = member.mediaRef
                offsetSeconds = member.sync.offsetSeconds
            }
        }

        let groupID: String
        let member: Member
        let microphones: [Member]
        let minimumPauseSeconds: Double
        let speechPaddingSeconds: Double

        init(
            group: MulticamSource,
            member: MulticamSource.Member,
            settings: SilenceRemovalSettings
        ) {
            groupID = group.id
            self.member = Member(member)
            microphones = group.mics.map(Member.init)
            minimumPauseSeconds = settings.minimumPauseSeconds
            speechPaddingSeconds = settings.speechPaddingSeconds
        }
    }

    private static let capacity = 256
    private var values: [Key: [Bool]] = [:]
    private var insertionOrder: [Key] = []

    func value(for key: Key, build: () -> [Bool]?) -> [Bool]? {
        if let cached = values[key] { return cached }
        guard let value = build() else { return nil }
        if values.count >= Self.capacity, let evicted = insertionOrder.first {
            values.removeValue(forKey: evicted)
            insertionOrder.removeFirst()
        }
        values[key] = value
        insertionOrder.append(key)
        return value
    }

    func reset() {
        values.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }
}

struct DeadAirSelectionError: Error, Equatable, Sendable {
    let message: String
}

/// Dead-air removal: maps SpeechMaskStore spans onto timeline ranges and ripple-deletes them.
extension EditorViewModel {

    func setMinimumSilenceDuration(_ seconds: Double) {
        guard let settings = SilenceRemovalSettings(
            minimumPauseSeconds: seconds,
            speechPaddingSeconds: silenceRemovalSettings.speechPaddingSeconds
        ) else { return }
        silenceRemovalSettings = settings
    }

    func setSpeechPaddingDuration(_ seconds: Double) {
        guard let settings = SilenceRemovalSettings(
            minimumPauseSeconds: silenceRemovalSettings.minimumPauseSeconds,
            speechPaddingSeconds: seconds
        ) else { return }
        silenceRemovalSettings = settings
    }

    /// The dead-air span under `timelineFrame` in `clip`, as a timeline range. Nil when the frame isn't dead air.
    func deadAirSpanRange(clip: Clip, atTimelineFrame frame: Int) -> FrameRange? {
        deadAirRanges(for: clip).first { $0.start <= frame && frame < $0.end }
    }

    /// Every dead-air span visible within `clip`, as timeline ranges.
    func deadAirRanges(
        for clip: Clip,
        settings: SilenceRemovalSettings? = nil
    ) -> [FrameRange] {
        let effectiveSettings = settings ?? silenceRemovalSettings
        return deadAirSourceRanges(for: clip, settings: effectiveSettings).compactMap {
            timelineRange(clip: clip, sourceStart: $0.lowerBound, sourceEnd: $0.upperBound)
        }
    }

    /// Dead-air ranges grouped by track; each track ripples its own spans.
    func allDeadAir(
        settings: SilenceRemovalSettings? = nil
    ) -> [(trackIndex: Int, ranges: [FrameRange])] {
        let effectiveSettings = settings ?? silenceRemovalSettings
        var out: [(Int, [FrameRange])] = []
        for (ti, track) in timeline.tracks.enumerated() where track.type == .audio {
            let ranges = RippleEngine.mergeRanges(
                track.clips.flatMap { deadAirRanges(for: $0, settings: effectiveSettings) }
            )
            if !ranges.isEmpty { out.append((ti, ranges)) }
        }
        return out
    }

    func removeDeadAir(clipId: String, atTimelineFrame frame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard let range = deadAirSpanRange(clip: clip, atTimelineFrame: frame) else { return }
        if case .refused(let reason) = rippleDeleteRangesOnTrack(trackIndex: loc.trackIndex, ranges: [range]) {
            NSSound.beep()
            Log.editor.notice("remove dead air blocked: \(reason)")
        }
    }

    /// Ripples every dead-air span within selected clips on one track or in one linked A/V unit.
    @discardableResult
    func removeDeadAir(
        clipIds: [String],
        settings: SilenceRemovalSettings
    ) throws -> (sections: Int, removedFrames: Int, refusal: String?)? {
        let targets = clipIds.compactMap { id -> (trackIndex: Int, clip: Clip)? in
            guard let loc = findClip(id: id) else { return nil }
            return (loc.trackIndex, timeline.tracks[loc.trackIndex].clips[loc.clipIndex])
        }
        guard targets.count == clipIds.count, !targets.isEmpty else {
            throw DeadAirSelectionError(message: "Selected clips could not be resolved.")
        }
        let audioTargets = targets.filter { $0.clip.mediaType == .audio }
        guard !audioTargets.isEmpty else {
            throw DeadAirSelectionError(message: "Selected clips must include at least one audio clip.")
        }

        let trackIndices = Set(targets.map(\.trackIndex))
        if trackIndices.count > 1 {
            let linkGroups = targets.compactMap { $0.clip.linkGroupId }
            guard linkGroups.count == targets.count, Set(linkGroups).count == 1 else {
                throw DeadAirSelectionError(
                    message: "Selected clips must share one track or belong to one linked A/V unit."
                )
            }
        }
        let audioTrackIndices = Set(audioTargets.map(\.trackIndex))
        guard audioTrackIndices.count == 1, let anchorTrackIndex = audioTrackIndices.first else {
            throw DeadAirSelectionError(message: "Selected audio clips must come from one track.")
        }

        let ranges = RippleEngine.mergeRanges(
            audioTargets.flatMap { deadAirRanges(for: $0.clip, settings: settings) }
        )
        guard !ranges.isEmpty else { return nil }
        return undo.perform("Remove Dead Air") {
            switch rippleDeleteRangesOnTrack(trackIndex: anchorTrackIndex, ranges: ranges) {
            case .ok(let report):
                return (ranges.count, report.removedFrames, nil)
            case .refused(let reason):
                NSSound.beep()
                Log.editor.notice("remove dead air blocked: \(reason)")
                return (0, 0, reason)
            }
        }
    }

    /// Ripples dead air per-track, updating ranges between passes. Stops if a track refuses.
    @discardableResult
    func removeAllDeadAir(
        settings: SilenceRemovalSettings? = nil
    ) -> (sections: Int, removedFrames: Int, refusal: String?)? {
        let effectiveSettings = settings ?? silenceRemovalSettings
        return undo.perform("Remove Dead Air") { () -> (sections: Int, removedFrames: Int, refusal: String?)? in
            var sections = 0
            var removedFrames = 0
            var refusal: String?
            for _ in timeline.tracks.indices {
                guard let next = allDeadAir(settings: effectiveSettings).first else { break }
                switch rippleDeleteRangesOnTrack(trackIndex: next.trackIndex, ranges: next.ranges) {
                case .ok(let report):
                    sections += next.ranges.count
                    removedFrames += report.removedFrames
                case .refused(let reason):
                    refusal = reason
                    NSSound.beep()
                    Log.editor.notice("remove dead air blocked: \(reason)")
                }
                if refusal != nil { break }
            }
            guard sections > 0 || refusal != nil else { return nil }
            return (sections, removedFrames, refusal)
        }
    }

    func deadAirSourceRanges(
        for clip: Clip,
        settings: SilenceRemovalSettings
    ) -> [Range<Double>] {
        let mask: [Bool]?
        if let group = multicamGroup(of: clip) {
            guard let member = group.member(mediaRef: clip.mediaRef) else { return [] }
            let key = DeadAirMaskCache.Key(
                group: group,
                member: member,
                settings: settings
            )
            mask = deadAirMaskCache.value(for: key) {
                DeadAirMaskResolver.mask(
                    for: clip,
                    in: group,
                    settings: settings,
                    quietMaskForMedia: { mediaVisualCache.quietNonSpeechMask(for: $0) }
                )
            }
        } else {
            mask = mediaVisualCache.deadAirMask(for: clip.mediaRef, settings: settings)
        }
        guard let mask, !mask.isEmpty else { return [] }
        let visibleStart = Double(clip.trimStartFrame)
        let visibleEnd = Double(clip.trimStartFrame + clip.sourceFramesConsumed)
        return SilenceRemovalPlanner.visibleRemovableRanges(
            from: mask,
            visibleSourceRange: visibleStart..<visibleEnd,
            framesPerSecond: timeline.fps,
            settings: settings
        )
    }

    private func timelineRange(clip: Clip, sourceStart: Double, sourceEnd: Double) -> FrameRange? {
        let s0 = max(sourceStart, Double(clip.trimStartFrame))
        let s1 = min(sourceEnd, Double(clip.trimStartFrame + clip.sourceFramesConsumed))
        guard s1 > s0, clip.speed > 0 else { return nil }
        let t0 = Double(clip.startFrame) + (s0 - Double(clip.trimStartFrame)) / clip.speed
        let t1 = Double(clip.startFrame) + (s1 - Double(clip.trimStartFrame)) / clip.speed
        let range = FrameRange(start: Int(t0.rounded()), end: Int(t1.rounded()))
        return range.length > 0 ? range : nil
    }
}
