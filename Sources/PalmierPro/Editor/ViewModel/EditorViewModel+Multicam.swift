import AppKit

extension EditorViewModel {

    struct MulticamMemberSpec {
        var mediaRef: String
        var kind: MulticamSource.MemberKind
        var angleLabel: String?
        var pinnedOffsetSeconds: Double?
    }

    struct MulticamSyncOutcome {
        var maps: [String: MulticamSource.SyncMap] = [:]
        var failures: [(mediaRef: String, reason: String)] = []
    }

    struct AngleSwitchRequest {
        var range: Range<Int>
        var angles: [String]
        var layout: VideoLayout = .full

        init(range: Range<Int>, angle: String) {
            self.range = range
            self.angles = [angle]
        }

        init(range: Range<Int>, layout: VideoLayout, angles: [String]) {
            self.range = range
            self.layout = layout
            self.angles = angles
        }
    }

    // MARK: - Lookup

    func multicamGroup(id: String) -> MulticamSource? {
        multicamGroups.first { $0.id == id }
    }

    func multicamGroup(of clip: Clip) -> MulticamSource? {
        clip.multicamGroupId.flatMap { multicamGroup(id: $0) }
    }

    func multicamClips(of groupId: String) -> [(trackIndex: Int, clip: Clip)] {
        timeline.tracks.indices.flatMap { ti in
            timeline.tracks[ti].clips.filter { $0.multicamGroupId == groupId }.map { (ti, $0) }
        }
    }

    func multicamTrackIndexes(of groupId: String) -> Set<Int> {
        Set(multicamClips(of: groupId).map(\.trackIndex))
    }

    func multicamSourceDurations(_ group: MulticamSource) -> [String: Double] {
        group.members.reduce(into: [:]) { out, member in
            out[member.mediaRef] = mediaAssets.first { $0.id == member.mediaRef }?.duration
        }
    }

    func multicamAngleLabel(for clip: Clip) -> String? {
        multicamGroup(of: clip)?.member(mediaRef: clip.mediaRef)?.angleLabel
    }

    func multicamAudioBearers(of group: MulticamSource) -> [MulticamSource.Member] {
        group.members.filter { member in
            member.usable && (member.providesAudio
                || mediaAssets.first { $0.id == member.mediaRef }?.hasAudio == true)
        }
    }

    func refuseWithToast(_ reason: String) {
        mediaPanelToast = MediaPanelToast(stringLiteral: reason)
        NSSound.beep()
    }

    func multicamMoveViolation(moves: [(clipId: String, toTrack: Int, toFrame: Int)]) -> String? {
        let infos = moves.compactMap { m in clipFor(id: m.clipId).map { ($0, m.toTrack, m.toFrame) } }
        let movedIds = Set(infos.map { $0.0.id })
        let horizontal = infos.contains { $0.0.startFrame != $0.2 }
        let laneChange = infos.contains { info in
            info.0.multicamGroupId != nil && info.0.mediaType != .audio
                && findClip(id: info.0.id)?.trackIndex != info.1
        }
        guard horizontal || laneChange else { return nil }
        if laneChange { return "Can't move a multicam camera clip to another track — the group's program track stays fixed." }
        for gid in Set(infos.compactMap { $0.0.multicamGroupId }) {
            let leftBehind = Set(multicamClips(of: gid).map { $0.clip.id }).subtracting(movedIds)
            if !leftBehind.isEmpty {
                let name = multicamGroup(id: gid)?.name ?? "Multicam"
                return "Can't move part of multicam group \"\(name)\" — its clips stay in sync and move together."
            }
        }
        return nil
    }

    func multicamTrimBounds(for clip: Clip) -> (left: Int, right: Int)? {
        guard let group = multicamGroup(of: clip),
              let member = group.member(mediaRef: clip.mediaRef) else { return nil }
        let fps = timeline.fps
        let own = member.anchorFrame(of: clip, fps: fps)
        var left = clip.trimStartFrame
        var right = clip.trimEndFrame
        for (_, other) in multicamClips(of: group.id) where other.id != clip.id {
            guard let m = group.member(mediaRef: other.mediaRef),
                  m.anchorFrame(of: other, fps: fps) != own else { continue }
            if other.endFrame <= clip.startFrame { left = min(left, clip.startFrame - other.endFrame) }
            if other.startFrame >= clip.endFrame { right = min(right, other.startFrame - clip.endFrame) }
        }
        return (max(0, left), max(0, right))
    }

    // MARK: - Source sync
    func syncMulticamMembers(
        specs: [MulticamMemberSpec],
        masterRef: String,
        searchWindowSeconds: Double = SyncDefaults.memberSearchWindowSeconds,
        rebase: Bool = true
    ) async -> MulticamSyncOutcome {
        var outcome = MulticamSyncOutcome()

        var pending: [MulticamMemberSpec] = []
        for spec in specs {
            if let pinned = spec.pinnedOffsetSeconds {
                outcome.maps[spec.mediaRef] = MulticamSource.SyncMap(offsetSeconds: pinned, confidence: 1, locked: true)
            } else if spec.mediaRef == masterRef {
                outcome.maps[spec.mediaRef] = MulticamSource.SyncMap(offsetSeconds: 0, confidence: 1)
            } else {
                pending.append(spec)
            }
        }
        guard !pending.isEmpty else { return rebase ? rebased(outcome) : outcome }

        let refs = Set([masterRef] + pending.map(\.mediaRef))
        let urls = refs.reduce(into: [String: URL]()) { $0[$1] = mediaResolver.resolveURL(for: $1) }
        let timing = await SourceTimingReader.cache(mediaRefs: refs, urls: urls)
        let masterOffset = outcome.maps[masterRef]?.offsetSeconds ?? 0

        func resolveWithoutAudio(_ ref: String, reason: String) {
            if let master = timing[masterRef]?.timecode, let tc = timing[ref]?.timecode {
                outcome.maps[ref] = MulticamSource.SyncMap(offsetSeconds: masterOffset + tc.seconds - master.seconds, confidence: 1)
            } else {
                outcome.maps[ref] = MulticamSource.SyncMap()
                outcome.failures.append((ref, reason))
            }
        }

        let envelopeSpan = 0...(searchWindowSeconds + 300)
        guard let masterURL = urls[masterRef],
              let masterEnv = try? await AudioEnvelopeExtractor.extract(from: masterURL, range: envelopeSpan),
              !masterEnv.samples.isEmpty else {
            outcome.failures.append((masterRef, "Master has no readable audio."))
            for spec in pending { resolveWithoutAudio(spec.mediaRef, reason: "No audio to sync with and no shared timecode.") }
            return rebase ? rebased(outcome) : outcome
        }

        let extracted = await withTaskGroup(of: (String, [Float]?).self) { group in
            for spec in pending {
                let url = urls[spec.mediaRef]
                group.addTask {
                    guard let url, let env = try? await AudioEnvelopeExtractor.extract(from: url, range: envelopeSpan) else {
                        return (spec.mediaRef, nil)
                    }
                    return (spec.mediaRef, env.samples.isEmpty ? nil : env.samples)
                }
            }
            var out: [String: [Float]] = [:]
            for await (ref, samples) in group { out[ref] = samples }
            return out
        }

        let hop = AudioEnvelopeExtractor.hopSeconds
        let seedWindow = max(1, Int((SyncDefaults.dateSeedWindowSeconds / hop).rounded()))
        let minOverlapHops = max(AudioSyncCorrelator.minOverlap, Int((SyncDefaults.minOverlapSeconds / hop).rounded()))

        struct Anchor {
            let offsetSeconds: Double
            let mediaRef: String
            let samples: [Float]
        }
        var anchors = [Anchor(offsetSeconds: masterOffset, mediaRef: masterRef, samples: masterEnv.samples)]

        func match(_ anchor: Anchor, ref: String, samples: [Float]) async -> (offset: Double, confidence: Double)? {
            var seed: Int?
            if let anchorDate = timing[anchor.mediaRef]?.captureDate, let date = timing[ref]?.captureDate {
                seed = Int((date.timeIntervalSince(anchorDate) / hop).rounded())
            }
            let maxLag = MulticamEngine.maxLagHops(
                windowSeconds: searchWindowSeconds, hopSeconds: hop,
                referenceCount: anchor.samples.count, targetCount: samples.count
            )
            guard let result = await AudioSyncCorrelator.seededCorrelate(
                reference: anchor.samples, target: samples, seedHops: seed, seedWindowHops: seedWindow,
                maxLagHops: maxLag, minOverlapHops: minOverlapHops, minConfidence: SyncDefaults.minConfidence
            ) else { return nil }
            return (anchor.offsetSeconds + Double(result.lagHops) * hop, result.confidence)
        }

        var candidates: [(ref: String, samples: [Float], direct: (offset: Double, confidence: Double)?)] = []
        for spec in pending {
            guard let samples = extracted[spec.mediaRef] else {
                resolveWithoutAudio(spec.mediaRef, reason: "No readable audio to sync with.")
                continue
            }
            candidates.append((spec.mediaRef, samples, await match(anchors[0], ref: spec.mediaRef, samples: samples)))
        }

        candidates.sort { ($0.direct?.confidence ?? 0) > ($1.direct?.confidence ?? 0) }
        for candidate in candidates {
            var best = candidate.direct
            for anchor in anchors.dropFirst() {
                if let hit = await match(anchor, ref: candidate.ref, samples: candidate.samples),
                   hit.confidence > (best?.confidence ?? 0) {
                    best = hit
                }
            }
            guard let best else {
                resolveWithoutAudio(candidate.ref, reason: "No confident alignment — pin an offset or re-sync with a wider window.")
                continue
            }
            outcome.maps[candidate.ref] = MulticamSource.SyncMap(
                offsetSeconds: best.offset, confidence: (best.confidence * 1000).rounded() / 1000
            )
            anchors.append(Anchor(offsetSeconds: best.offset, mediaRef: candidate.ref, samples: candidate.samples))
        }
        return rebase ? rebased(outcome) : outcome
    }

    private func rebased(_ outcome: MulticamSyncOutcome) -> MulticamSyncOutcome {
        var outcome = outcome
        let base = outcome.maps.values.filter { $0.confidence > 0 || $0.locked }.map(\.offsetSeconds).min() ?? 0
        if base != 0 {
            for (ref, var map) in outcome.maps where map.confidence > 0 || map.locked {
                map.offsetSeconds -= base
                outcome.maps[ref] = map
            }
        }
        return outcome
    }

    // MARK: - Creation
    @discardableResult
    func createMulticamGroup(
        specs: [MulticamMemberSpec],
        syncMaps: [String: MulticamSource.SyncMap],
        masterRef: String,
        name: String?,
        startFrame: Int? = nil
    ) throws -> (groupId: String, clipIds: [String]) {
        var members: [MulticamSource.Member] = []
        var usedLabels = Set<String>()
        for spec in specs {
            let asset = mediaAssets.first { $0.id == spec.mediaRef }
            let label = uniqueAngleLabel(spec.angleLabel ?? asset?.name ?? spec.mediaRef, used: &usedLabels)
            members.append(MulticamSource.Member(
                mediaRef: spec.mediaRef,
                kind: spec.kind,
                angleLabel: label,
                sync: syncMaps[spec.mediaRef] ?? MulticamSource.SyncMap()
            ))
        }
        guard let master = members.first(where: { $0.mediaRef == masterRef }) else {
            throw ToolError("Master member not found among members.")
        }

        let group = MulticamSource(
            name: name ?? uniqueName({ "Multicam \($0)" }, startingAt: 1),
            members: members, masterMemberId: master.id
        )
        let durations = multicamSourceDurations(group)
        let fps = timeline.fps
        let at = startFrame ?? timeline.totalFrames

        let angleRanges = group.angles.compactMap { angle in
            durations[angle.mediaRef].map { angle.coverage(sourceDuration: $0, fps: fps) }
        }
        guard let videoStart = angleRanges.map(\.lowerBound).min(),
              let videoEnd = angleRanges.map(\.upperBound).max(), videoStart < videoEnd,
              let seed = group.angles.first(where: { durations[$0.mediaRef] != nil }) else {
            throw ToolError("No synced camera has picture — nothing to place.")
        }

        let groupOrigin = at - videoStart

        func memberClip(_ member: MulticamSource.Member, groupRange: Range<Int>, mediaType: ClipType) -> Clip? {
            makeMemberClip(member, groupRange: groupRange, mediaType: mediaType,
                           groupId: group.id, groupOrigin: groupOrigin, fps: fps,
                           sourceDuration: durations[member.mediaRef])
        }

        var programSpans: [(member: MulticamSource.Member, range: Range<Int>)] = []
        var holes: [Range<Int>] = [videoStart..<videoEnd]
        for angle in [seed] + group.angles.filter({ $0.id != seed.id }) {
            guard let duration = durations[angle.mediaRef] else { continue }
            let coverage = angle.coverage(sourceDuration: duration, fps: fps)
            var remaining: [Range<Int>] = []
            for hole in holes {
                let filled = hole.clamped(to: coverage)
                if filled.isEmpty { remaining.append(hole); continue }
                programSpans.append((angle, filled))
                if hole.lowerBound < filled.lowerBound { remaining.append(hole.lowerBound..<filled.lowerBound) }
                if filled.upperBound < hole.upperBound { remaining.append(filled.upperBound..<hole.upperBound) }
            }
            holes = remaining
            if holes.isEmpty { break }
        }
        programSpans.sort { $0.range.lowerBound < $1.range.lowerBound }

        return try undo.perform("Create Multicam") {
            var clipIds: [String] = []
            withTimelineSwap(actionName: "Create Multicam") {
                let videoIdx = insertTrack(at: 0, type: .video)
                for span in programSpans {
                    guard let clip = memberClip(span.member, groupRange: span.range, mediaType: .video) else { continue }
                    timeline.tracks[videoIdx].clips.append(clip)
                    clipIds.append(clip.id)
                }

                var audioInsert = timeline.tracks.count
                for mic in group.mics {
                    guard let duration = durations[mic.mediaRef],
                          let clip = memberClip(mic, groupRange: mic.coverage(sourceDuration: duration, fps: fps), mediaType: .audio)
                    else { continue }
                    let idx = insertTrack(at: audioInsert, type: .audio)
                    timeline.tracks[idx].clips.append(clip)
                    clipIds.append(clip.id)
                    audioInsert = idx + 1
                }
            }
            guard !clipIds.isEmpty else {
                throw ToolError("Could not place the multicam on the timeline.")
            }
            insertMulticamGroup(group, actionName: "Create Multicam")
            return (group.id, clipIds)
        }
    }

    private func makeMemberClip(
        _ member: MulticamSource.Member, groupRange: Range<Int>, mediaType: ClipType,
        groupId: String, groupOrigin: Int, fps: Int, sourceDuration: Double?
    ) -> Clip? {
        let start = groupOrigin + groupRange.lowerBound
        let clampedRange = max(0, start)..<(groupOrigin + groupRange.upperBound)
        guard !clampedRange.isEmpty else { return nil }
        let headCut = clampedRange.lowerBound - start

        var clip = Clip(mediaRef: member.mediaRef,
                        startFrame: clampedRange.lowerBound,
                        durationFrames: clampedRange.count)
        clip.mediaType = mediaType
        clip.sourceClipType = mediaAssets.first { $0.id == member.mediaRef }?.type ?? mediaType
        clip.multicamGroupId = groupId
        clip.trimStartFrame = member.trimFrame(atGroupFrame: groupRange.lowerBound, fps: fps) + headCut
        if let sourceDuration {
            let sourceLen = Int((sourceDuration * Double(fps)).rounded())
            clip.trimEndFrame = max(0, sourceLen - clip.trimStartFrame - clip.sourceFramesConsumed)
        }
        if mediaType == .video, let asset = mediaAssets.first(where: { $0.id == member.mediaRef }) {
            clip.transform = fitTransform(for: asset, canvasWidth: timeline.width, canvasHeight: timeline.height)
        }
        return clip
    }

    private func uniqueAngleLabel(_ raw: String, used: inout Set<String>) -> String {
        var base = raw.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { if !($0.hasSuffix("-") && $1 == "-") { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "angle" }
        var label = base
        var n = 2
        while !used.insert(label).inserted {
            label = "\(base)-\(n)"
            n += 1
        }
        return label
    }

    // MARK: - Group metadata undo

    private func insertMulticamGroup(_ group: MulticamSource, actionName: String) {
        multicamGroups.append(group)
        undo.register(actionName, withTarget: self) { vm in
            vm.removeMulticamGroupMetadata(id: group.id, actionName: actionName)
        }
    }

    private func removeMulticamGroupMetadata(id: String, actionName: String) {
        guard let group = multicamGroup(id: id) else { return }
        multicamGroups.removeAll { $0.id == id }
        undo.register(actionName, withTarget: self) { vm in
            vm.insertMulticamGroup(group, actionName: actionName)
        }
    }

    func referencedMulticamGroupIds() -> Set<String> {
        Set(timelines.flatMap { t in t.tracks.flatMap { $0.clips.compactMap(\.multicamGroupId) } })
    }

    func savedMulticamGroups() -> [MulticamSource]? {
        let referenced = referencedMulticamGroupIds()
        let live = multicamGroups.filter { referenced.contains($0.id) }
        return live.isEmpty ? nil : live
    }

    // MARK: - Lifecycle

    func ungroupMulticam(groupId: String) {
        guard multicamGroup(id: groupId) != nil else { return }
        undo.perform("Ungroup Multicam") {
            withTimelineSwap(actionName: "Ungroup Multicam") {
                for ti in timeline.tracks.indices {
                    for ci in timeline.tracks[ti].clips.indices
                    where timeline.tracks[ti].clips[ci].multicamGroupId == groupId {
                        timeline.tracks[ti].clips[ci].multicamGroupId = nil
                    }
                }
            }
            let stillReferenced = timelines.contains { t in
                t.tracks.contains { $0.clips.contains { $0.multicamGroupId == groupId } }
            }
            if !stillReferenced {
                removeMulticamGroupMetadata(id: groupId, actionName: "Ungroup Multicam")
            }
        }
    }

    // MARK: - Angle switching

    func switchMulticamAngles(groupId: String, requests: [AngleSwitchRequest]) throws -> MulticamEngine.Outcome {
        guard let group = multicamGroup(id: groupId) else {
            throw ToolError("Not a multicam group: \(groupId)")
        }
        guard !multicamClips(of: groupId).isEmpty else {
            throw ToolError("The group has no clips on the active timeline.")
        }
        let entries = try requests.map { request -> MulticamEngine.Entry in
            guard !request.angles.isEmpty, request.angles.count <= request.layout.slots.count else {
                throw ToolError("Layout \(request.layout.rawValue) takes at most \(request.layout.slots.count) angle(s): \(request.layout.slots.map(\.id).joined(separator: ", ")).")
            }
            return MulticamEngine.Entry(range: request.range,
                                        slots: try request.angles.map { try resolveMember($0, group: group) },
                                        layout: request.layout)
        }
        var outcome = MulticamEngine.Outcome()
        withTimelineSwap(actionName: "Switch Angle") {
            var working = timeline
            outcome = MulticamEngine.apply(
                entries: entries,
                to: &working,
                group: group,
                sourceDurations: multicamSourceDurations(group),
                fitTransform: { [self] clip in fitTransform(for: clip) },
                placement: { [self] clip, rect in layoutPlacement(for: clip, in: rect, fit: .fill) }
            )
            timeline = working
        }
        return outcome
    }

    /// Lay out the fragment with its current angle in slot 1; other synced
    /// angles fill remaining slots (partial fill is fine). `.full` exits.
    func applyMulticamLayout(clipId: String, layout: VideoLayout) {
        guard let clip = clipFor(id: clipId), let group = multicamGroup(of: clip) else { return }
        var ordered = group.angles
        if let idx = ordered.firstIndex(where: { $0.mediaRef == clip.mediaRef }) {
            ordered.swapAt(0, idx)
        }
        let angles = Array(ordered.prefix(layout.slots.count)).map(\.angleLabel)
        switchOrToast(groupId: group.id, request:
            AngleSwitchRequest(range: clip.startFrame..<clip.endFrame, layout: layout, angles: angles))
    }

    private func resolveMember(_ label: String, group: MulticamSource, audio: Bool = false) throws -> MulticamSource.Member {
        let noun = audio ? "mic" : "angle"
        let candidates = audio ? multicamAudioBearers(of: group) : group.angles
        guard let member = group.member(labeled: label),
              audio ? candidates.contains(where: { $0.id == member.id }) : member.providesVideo else {
            throw ToolError("Unknown \(noun) '\(label)'. \(noun.capitalized)s: \(candidates.map(\.angleLabel).joined(separator: ", ")).")
        }
        guard member.usable else {
            throw ToolError("\(noun.capitalized) '\(label)' isn't synced — pin an offset or recreate the group.")
        }
        return member
    }

    // MARK: - Program read

    func multicamProgramRows(groupId: String, window: Range<Int>? = nil) -> [[Any]] {
        guard let group = multicamGroup(id: groupId) else { return [] }
        let programClips = multicamClips(of: groupId)
            .filter { timeline.tracks[$0.trackIndex].type == .video && $0.clip.mediaType != .audio }
        guard let programTrack = programClips.map(\.trackIndex).max() else { return [] }

        var rows: [[Any]] = []
        for (ti, clip) in programClips.sorted(by: { $0.clip.startFrame < $1.clip.startFrame }) where ti == programTrack {
            var r = clip.startFrame..<clip.endFrame
            if let window { r = r.clamped(to: window) }
            guard !r.isEmpty else { continue }
            let label = group.member(mediaRef: clip.mediaRef)?.angleLabel ?? ""
            if var last = rows.last, last[0] as? String == label, last[2] as? Int == r.lowerBound {
                last[2] = r.upperBound
                rows[rows.count - 1] = last
            } else {
                rows.append([label, r.lowerBound, r.upperBound])
            }
        }
        return rows
    }

    // MARK: - Manual switching

    func switchMulticamSegment(clipId: String, to angle: String) {
        guard let loc = findClip(id: clipId), let group = multicamGroup(of: timeline.tracks[loc.trackIndex].clips[loc.clipIndex]) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let programTrack = multicamClips(of: group.id)
            .filter { timeline.tracks[$0.trackIndex].type == .video && $0.clip.mediaType != .audio }
            .map(\.trackIndex).max()
        if clip.mediaType == .audio || loc.trackIndex != programTrack {
            do {
                let member = try resolveMember(angle, group: group, audio: clip.mediaType == .audio)
                withTimelineSwap(actionName: clip.mediaType == .audio ? "Switch Mic" : "Switch Angle") {
                    MulticamEngine.rewrite(&timeline.tracks[loc.trackIndex].clips[loc.clipIndex],
                                           group: group, to: member,
                                           sourceDurations: multicamSourceDurations(group), fps: timeline.fps)
                }
            } catch let error as ToolError {
                mediaPanelToast = MediaPanelToast(stringLiteral: error.message)
            } catch {}
            return
        }
        switchOrToast(groupId: group.id, request:
            AngleSwitchRequest(range: clip.startFrame..<clip.endFrame, angle: angle))
    }

    private func switchOrToast(groupId: String, request: AngleSwitchRequest) {
        do { _ = try switchMulticamAngles(groupId: groupId, requests: [request]) }
        catch let error as ToolError { mediaPanelToast = MediaPanelToast(stringLiteral: error.message) }
        catch { mediaPanelToast = "Couldn't switch angle." }
    }

    func switchMulticamRange(groupId: String, range: Range<Int>, angle: String) {
        switchOrToast(groupId: groupId, request:
            AngleSwitchRequest(range: range, angle: angle))
    }

    // MARK: - Dead air (remove_silence)

    func multicamDeadAirMask(for clip: Clip) -> [Bool]? {
        guard clip.mediaType == .audio, let group = multicamGroup(of: clip) else { return nil }
        let mics = group.mics
        guard !mics.isEmpty else { return nil }
        let cellSeconds = VoiceActivity.chunkDuration
        var masks: [[Bool]] = []
        for mic in mics {
            guard let mask = mediaVisualCache.deadAirMask(for: mic.mediaRef), !mask.isEmpty else { return nil }
            let shift = Int((mic.sync.offsetSeconds / cellSeconds).rounded())
            var shifted = [Bool](repeating: true, count: max(0, mask.count + shift))
            for (i, dead) in mask.enumerated() where i + shift >= 0 && i + shift < shifted.count {
                shifted[i + shift] = dead
            }
            masks.append(shifted)
        }
        return (0..<(masks.map(\.count).max() ?? 0)).map { i in masks.allSatisfy { i >= $0.count || $0[i] } }
    }
}
