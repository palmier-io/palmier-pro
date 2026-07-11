import Foundation

enum MulticamEngine {

    struct Entry {
        var range: Range<Int>
        var slots: [MulticamSource.Member]
        var layout: VideoLayout = .full

        var member: MulticamSource.Member { slots[0] }
    }

    struct Outcome {
        var switched = 0
        var merged = 0
        var applied: [Range<Int>] = []
        var clamped: [(requested: Range<Int>, applied: Range<Int>, culprit: String)] = []
        var skipped: [(range: Range<Int>, reason: String)] = []
        var overlayClipIds: [String] = []
    }

    static func maxLagHops(windowSeconds: Double, hopSeconds: Double, referenceCount: Int, targetCount: Int) -> Int {
        let windowHops = Int((windowSeconds / hopSeconds).rounded())
        return max(1, min(windowHops, min(referenceCount, targetCount) / 2))
    }

    typealias Placement = (Clip, LayoutRect) -> (transform: Transform, crop: Crop)

    static func apply(
        entries: [Entry],
        to timeline: inout Timeline,
        group: MulticamSource,
        sourceDurations: [String: Double],
        fitTransform: (Clip) -> Transform,
        placement: Placement
    ) -> Outcome {
        var outcome = Outcome()
        let fps = timeline.fps

        for entry in entries where !entry.range.isEmpty {
            guard let programId = programTrackId(in: timeline, group: group, range: entry.range) else {
                outcome.skipped.append((entry.range, "no multicam clip in this range"))
                continue
            }
            let fragmentIds = clips(in: timeline, trackId: programId)
                .filter { isProgramFragment($0, group: group) && $0.overlaps(entry.range) }
                .map(\.id)

            for fragmentId in fragmentIds {
                guard let fragment = clips(in: timeline, trackId: programId).first(where: { $0.id == fragmentId }),
                      let member = group.member(mediaRef: fragment.mediaRef) else { continue }

                let wanted = entry.range.clamped(to: fragment.startFrame..<fragment.endFrame)
                let (target, culprit) = clampToCoverage(
                    wanted, fragment: fragment, current: member,
                    target: entry.member, sourceDurations: sourceDurations, fps: fps
                )
                if target.isEmpty {
                    outcome.skipped.append((wanted, "\(culprit ?? "an angle") wasn't recording here"))
                    continue
                }
                if let culprit { outcome.clamped.append((wanted, target, culprit)) }

                let hadLayout = clearOverlays(over: target, abovePrograms: programId, in: &timeline, groupId: group.id) > 0
                let programRect = entry.layout.slots.first?.rect
                for (slot, slotMember) in zip(entry.layout.slots.dropFirst(), entry.slots.dropFirst()) {
                    if let id = placeOverlay(slotMember, over: target, anchor: fragment, anchorMember: member,
                                             abovePrograms: programId, in: &timeline, group: group,
                                             sourceDurations: sourceDurations, fps: fps,
                                             style: { placement($0, slot.rect) }) {
                        outcome.overlayClipIds.append(id)
                    }
                }

                withTrack(&timeline, id: programId) { track in
                    split(track: &track, at: target.lowerBound)
                    split(track: &track, at: target.upperBound)
                    for i in track.clips.indices where isProgramFragment(track.clips[i], group: group)
                        && track.clips[i].startFrame >= target.lowerBound
                        && track.clips[i].endFrame <= target.upperBound {
                        let wasDefaultFit = track.clips[i].transform == fitTransform(track.clips[i])
                            && track.clips[i].crop == Crop()
                        rewrite(&track.clips[i], group: group, to: entry.member,
                                sourceDurations: sourceDurations, fps: fps)
                        if entry.layout != .full, let programRect {
                            let placed = placement(track.clips[i], programRect)
                            track.clips[i].transform = placed.transform
                            track.clips[i].crop = placed.crop
                        } else if wasDefaultFit || hadLayout {
                            track.clips[i].transform = fitTransform(track.clips[i])
                            if hadLayout { track.clips[i].crop = Crop() }
                        }
                        outcome.switched += 1
                    }
                    outcome.merged += joinThroughEdits(track: &track, within: [target], groupId: group.id)
                }
                outcome.applied.append(target)
            }
        }
        return outcome
    }

    // MARK: - Addressing

    private static func clips(in timeline: Timeline, trackId: String) -> [Clip] {
        timeline.tracks.first { $0.id == trackId }?.clips ?? []
    }

    private static func withTrack(_ timeline: inout Timeline, id: String, _ body: (inout Track) -> Void) {
        guard let i = timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        body(&timeline.tracks[i])
    }

    private static func isProgramFragment(_ clip: Clip, group: MulticamSource) -> Bool {
        clip.multicamGroupId == group.id && clip.mediaType != .audio
    }

    private static func programTrackId(in timeline: Timeline, group: MulticamSource, range: Range<Int>) -> String? {
        timeline.tracks.last {
            $0.type == .video && $0.clips.contains { isProgramFragment($0, group: group) && $0.overlaps(range) }
        }?.id
    }

    private static func clampToCoverage(
        _ wanted: Range<Int>,
        fragment: Clip,
        current: MulticamSource.Member,
        target: MulticamSource.Member,
        sourceDurations: [String: Double],
        fps: Int
    ) -> (Range<Int>, culprit: String?) {
        guard let duration = sourceDurations[target.mediaRef] else { return (wanted, nil) }
        let groupStart = Double(fragment.trimStartFrame) / Double(fps) + current.sync.offsetSeconds
        func projectFrame(_ groupSeconds: Double) -> Int {
            fragment.startFrame + Int(((groupSeconds - groupStart) * Double(fps)).rounded())
        }
        let coverage = projectFrame(target.sync.offsetSeconds)..<projectFrame(target.sync.offsetSeconds + duration)
        let clamped = wanted.clamped(to: coverage)
        return (clamped, clamped == wanted ? nil : target.angleLabel)
    }

    private static func placeOverlay(
        _ member: MulticamSource.Member,
        over range: Range<Int>,
        anchor: Clip,
        anchorMember: MulticamSource.Member,
        abovePrograms programId: String,
        in timeline: inout Timeline,
        group: MulticamSource,
        sourceDurations: [String: Double],
        fps: Int,
        style: (Clip) -> (transform: Transform, crop: Crop)
    ) -> String? {
        var clip = Clip(mediaRef: member.mediaRef, startFrame: range.lowerBound, durationFrames: range.count)
        clip.multicamGroupId = group.id
        let groupFrame = range.lowerBound - anchorMember.anchorFrame(of: anchor, fps: fps)
        clip.trimStartFrame = groupFrame - member.offsetFrames(fps: fps)
        if let duration = sourceDurations[member.mediaRef] {
            let sourceLen = Int((duration * Double(fps)).rounded())
            clip.trimEndFrame = max(0, sourceLen - clip.trimStartFrame - clip.sourceFramesConsumed)
        }
        let placed = style(clip)
        clip.transform = placed.transform
        clip.crop = placed.crop

        guard let programIdx = timeline.tracks.firstIndex(where: { $0.id == programId }) else { return nil }
        let free = timeline.tracks[..<programIdx].lastIndex { track in
            track.type == .video && !track.clips.contains { $0.overlaps(range) }
        }
        let idx = free ?? {
            timeline.tracks.insert(Track(type: .video), at: programIdx)
            return programIdx
        }()
        timeline.tracks[idx].clips.append(clip)
        timeline.tracks[idx].clips.sort { $0.startFrame < $1.startFrame }
        return clip.id
    }

    @discardableResult
    private static func clearOverlays(
        over range: Range<Int>, abovePrograms programId: String,
        in timeline: inout Timeline, groupId: String
    ) -> Int {
        guard let programIdx = timeline.tracks.firstIndex(where: { $0.id == programId }) else { return 0 }
        var removed = 0
        for trackId in timeline.tracks[..<programIdx].map(\.id) {
            withTrack(&timeline, id: trackId) { track in
                split(track: &track, at: range.lowerBound, onlyGroup: groupId)
                split(track: &track, at: range.upperBound, onlyGroup: groupId)
                let before = track.clips.count
                track.clips.removeAll {
                    $0.multicamGroupId == groupId && $0.startFrame >= range.lowerBound && $0.endFrame <= range.upperBound
                }
                removed += before - track.clips.count
            }
        }
        return removed
    }

    // MARK: - Clip surgery

    static func rewrite(
        _ clip: inout Clip,
        group: MulticamSource,
        to member: MulticamSource.Member,
        sourceDurations: [String: Double],
        fps: Int
    ) {
        guard clip.mediaRef != member.mediaRef,
              let current = group.member(mediaRef: clip.mediaRef) else { return }
        let delta = Int(((current.sync.offsetSeconds - member.sync.offsetSeconds) * Double(fps)).rounded())
        clip.mediaRef = member.mediaRef
        clip.trimStartFrame += delta
        if let duration = sourceDurations[member.mediaRef] {
            let sourceLen = Int((duration * Double(fps)).rounded())
            clip.trimEndFrame = max(0, sourceLen - clip.trimStartFrame - clip.sourceFramesConsumed)
        } else {
            clip.trimEndFrame = 0
        }
    }

    @discardableResult
    private static func split(track: inout Track, at frame: Int, onlyGroup groupId: String? = nil) -> Bool {
        guard let i = track.clips.firstIndex(where: {
            frame > $0.startFrame && frame < $0.endFrame && (groupId == nil || $0.multicamGroupId == groupId)
        }), let (left, right) = EditorViewModel.splitValues(of: track.clips[i], atFrame: frame) else { return false }
        track.clips[i] = left
        track.clips.insert(right, at: i + 1)
        return true
    }

    // MARK: - Sanitization

    private static func isThroughEdit(_ a: Clip, _ b: Clip) -> Bool {
        a.mediaRef == b.mediaRef
            && a.mediaType == b.mediaType
            && a.multicamGroupId == b.multicamGroupId
            && b.startFrame == a.endFrame
            && b.trimStartFrame == a.trimStartFrame + a.sourceFramesConsumed
            && a.speed == b.speed
            && a.volume == b.volume
            && a.opacity == b.opacity
            && a.transform == b.transform
            && a.crop == b.crop
            && a.effects == b.effects
            && a.blendMode == b.blendMode
            && a.fadeOutFrames == 0 && b.fadeInFrames == 0
            && !a.hasKeyframes && !b.hasKeyframes
    }

    private static func joinThroughEdits(track: inout Track, within ranges: [Range<Int>], groupId: String) -> Int {
        guard !ranges.isEmpty else { return 0 }
        var merged = 0
        var clips = track.clips.sorted { $0.startFrame < $1.startFrame }
        var i = 0
        while i + 1 < clips.count {
            let seam = clips[i].endFrame
            if clips[i].multicamGroupId == groupId,
               ranges.contains(where: { $0.lowerBound <= seam && seam <= $0.upperBound }),
               isThroughEdit(clips[i], clips[i + 1]) {
                clips[i].durationFrames += clips[i + 1].durationFrames
                clips[i].trimEndFrame = clips[i + 1].trimEndFrame
                clips[i].fadeOutFrames = clips[i + 1].fadeOutFrames
                clips.remove(at: i + 1)
                merged += 1
            } else {
                i += 1
            }
        }
        track.clips = clips
        return merged
    }
}

private extension Clip {
    func overlaps(_ range: Range<Int>) -> Bool {
        startFrame < range.upperBound && endFrame > range.lowerBound
    }

    var hasKeyframes: Bool {
        opacityTrack != nil || positionTrack != nil || scaleTrack != nil
            || rotationTrack != nil || cropTrack != nil || volumeTrack != nil
    }
}
