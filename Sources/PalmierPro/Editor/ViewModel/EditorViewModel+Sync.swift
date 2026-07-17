import Foundation

extension EditorViewModel {
    enum SyncMode: String, Sendable { case auto, audio, timecode }
    enum SyncMethod: String, Sendable { case timecode, audio }

    struct SyncBatchReport: Sendable {
        var synced: [(clipId: String, offsetFrames: Int, confidence: Double, method: SyncMethod)] = []
        var failures: [(clipId: String, message: String)] = []
        /// Frames the whole group (reference included) moved right so no target lands before frame 0.
        var shiftedFrames: Int = 0
        var retimed: [(clipId: String, driftPpm: Double)] = []
        var retimeSkipped: [(clipId: String, message: String)] = []
    }

    enum SyncDefaults {
        static let minConfidence: Double = 0.5
        static let minSpeed: Double = 0.0001
        /// ± window around a capture-date seed; covers typical device clock skew.
        static let dateSeedWindowSeconds: Double = 3
        /// Thinner overlaps produce spurious edge matches that can beat the true alignment.
        static let minOverlapSeconds: Double = 3
        static let memberSearchWindowSeconds: Double = 240
    }

    /// Timeline start frame that aligns the target's first frame to the reference by wall-clock timecode.
    nonisolated static func timecodeAlignedStart(
        refStartFrame: Int, refTrimStartFrame: Int, refSpeed: Double, refTimecode: SourceTimecode,
        targetTrimStartFrame: Int, targetTimecode: SourceTimecode, fps: Double
    ) -> Int {
        let refClock = refTimecode.seconds + Double(refTrimStartFrame) / fps
        let targetClock = targetTimecode.seconds + Double(targetTrimStartFrame) / fps
        let lagFrames = (targetClock - refClock) * fps / max(refSpeed, SyncDefaults.minSpeed)
        return Int((Double(refStartFrame) + lagFrames).rounded())
    }

    @discardableResult
    func syncClips(
        referenceClipId: String,
        targetClipIds: [String],
        mode: SyncMode = .auto,
        searchWindowSeconds: Double? = nil,
        minConfidence: Double = SyncDefaults.minConfidence,
        applying mutation: (@MainActor (@MainActor () -> Void) async throws -> Void)? = nil
    ) async throws -> SyncBatchReport {
        let fps = Double(timeline.fps)
        let targets = targetClipIds.filter { $0 != referenceClipId }
        var report = SyncBatchReport()

        guard fps > 0, let refLoc = findClip(id: referenceClipId) else {
            return SyncBatchReport(failures: targets.map { ($0, "Reference clip unavailable.") })
        }
        let refClip = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
        let refUnitKey = refClip.linkGroupId ?? refClip.id

        func unit(of clip: Clip) -> [Clip] {
            guard let group = clip.linkGroupId else { return [clip] }
            return timeline.tracks.flatMap(\.clips).filter { $0.linkGroupId == group }
        }
        func liveClip(_ id: String) -> Clip? {
            findClip(id: id).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] }
        }

        var refs = Set(unit(of: refClip).map(\.mediaRef))
        for id in targets {
            guard let clip = liveClip(id) else { continue }
            refs.formUnion(unit(of: clip).map(\.mediaRef))
        }
        let timingCache = await SourceTimingReader.cache(
            mediaRefs: refs, urls: refs.reduce(into: [:]) { $0[$1] = mediaResolver.resolveURL(for: $1) })

        func tcCarrier(in clips: [Clip]) -> (clip: Clip, tc: SourceTimecode)? {
            let hits = clips.compactMap { c in timingCache[c.mediaRef]?.timecode.map { (c, $0) } }
            return hits.first { $0.0.mediaType.isVisual } ?? hits.first
        }
        let refTCCarrier = mode == .audio ? nil : tcCarrier(in: unit(of: refClip))

        let hop = AudioEnvelopeExtractor.hopSeconds
        let seedWindow = max(1, Int((SyncDefaults.dateSeedWindowSeconds / hop).rounded()))
        let minOverlap = max(AudioSyncCorrelator.minOverlap, Int((SyncDefaults.minOverlapSeconds / hop).rounded()))

        struct AudioClip {
            let clipId: String
            let samples: [Float]
            let speed: Double
            let mediaRef: String
            let trimStartFrame: Int
        }
        typealias Hit = (rawStart: Int, confidence: Double, driftRatio: Double, retimedSpeed: Double?)
        var anchors: [(rawStart: Int, clip: AudioClip)] = []
        var candidates: [(clip: AudioClip, direct: Hit?, tcRawStart: Int?)] = []
        var placements: [(clipId: String, rawStart: Int, confidence: Double, method: SyncMethod,
                          driftRatio: Double, retimedSpeed: Double?)] = []
        var refAudioTried = false

        func match(_ anchor: (rawStart: Int, clip: AudioClip), _ target: AudioClip) async -> Hit? {
            var seedHops: Int?
            if let anchorDate = timingCache[anchor.clip.mediaRef]?.captureDate,
               let targetDate = timingCache[target.mediaRef]?.captureDate {
                let lagSeconds = targetDate.timeIntervalSince(anchorDate)
                    + Double(target.trimStartFrame - anchor.clip.trimStartFrame) / fps
                seedHops = Int((lagSeconds / hop).rounded())
            }
            let maxLag = searchWindowSeconds.map { max(1, Int(($0 / hop).rounded())) }
                ?? max(anchor.clip.samples.count, target.samples.count)
            guard let result = await AudioSyncCorrelator.seededCorrelate(
                reference: anchor.clip.samples, target: target.samples, seedHops: seedHops,
                seedWindowHops: seedWindow, maxLagHops: maxLag, minOverlapHops: minOverlap,
                minConfidence: minConfidence
            ) else { return nil }
            let lagFrames = result.exactLagHops * hop * fps / max(anchor.clip.speed, SyncDefaults.minSpeed)
            var retimedSpeed: Double?
            if result.driftRatio != 0 {
                let corrected = anchor.clip.speed / (1 + result.driftRatio)
                if abs(corrected / max(target.speed, SyncDefaults.minSpeed) - 1) <= 0.001 {
                    retimedSpeed = corrected
                }
            }
            return (Int((Double(anchor.rawStart) + lagFrames).rounded()), result.confidence,
                    result.driftRatio, retimedSpeed)
        }

        var seenUnits = Set<String>()
        for targetId in targets {
            try Task.checkCancellation()
            guard let targetClip = liveClip(targetId) else { report.failures.append((targetId, "Clip not found.")); continue }
            let unitKey = targetClip.linkGroupId ?? targetClip.id
            if unitKey == refUnitKey {
                report.failures.append((targetId, "Clip is linked to the reference — they already move together.")); continue
            }
            guard seenUnits.insert(unitKey).inserted else { continue }
            let unitClips = unit(of: targetClip)

            var tcHint: (clipId: String, rawStart: Int)?
            if let (refCarrier, refTC) = refTCCarrier, let (carrier, targetTC) = tcCarrier(in: unitClips) {
                guard let liveRef = liveClip(refCarrier.id), let liveCarrier = liveClip(carrier.id) else {
                    report.failures.append((targetId, "Clip not found.")); continue
                }
                let rawStart = Self.timecodeAlignedStart(
                    refStartFrame: liveRef.startFrame, refTrimStartFrame: liveRef.trimStartFrame,
                    refSpeed: liveRef.speed, refTimecode: refTC,
                    targetTrimStartFrame: liveCarrier.trimStartFrame, targetTimecode: targetTC, fps: fps)
                if mode == .timecode {
                    placements.append((carrier.id, rawStart, 1.0, .timecode, 0, nil))
                    continue
                }
                tcHint = (carrier.id, rawStart)
            }
            if mode == .timecode {
                report.failures.append((targetId, refTCCarrier == nil
                    ? "Reference has no source timecode." : "Clip has no source timecode."))
                continue
            }

            guard let bearer = unitClips.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unitClips.first(where: { captionCanTranscribe($0) }) else {
                if let tcHint { placements.append((tcHint.clipId, tcHint.rawStart, 1.0, .timecode, 0, nil)); continue }
                report.failures.append((targetId, mode == .auto
                    ? "No source timecode, and clip has no audio." : "Clip has no audio."))
                continue
            }
            guard let env = await envelope(of: bearer, fps: fps), !env.samples.isEmpty else {
                if let tcHint { placements.append((tcHint.clipId, tcHint.rawStart, 1.0, .timecode, 0, nil)); continue }
                report.failures.append((bearer.id, "Clip has no audio.")); continue
            }
            if !refAudioTried {
                refAudioTried = true
                if let liveRef = liveClip(referenceClipId),
                   let refEnv = await envelope(of: liveRef, fps: fps), !refEnv.samples.isEmpty {
                    anchors.append((liveRef.startFrame, AudioClip(
                        clipId: liveRef.id, samples: refEnv.samples, speed: liveRef.speed,
                        mediaRef: liveRef.mediaRef, trimStartFrame: liveRef.trimStartFrame)))
                }
            }
            guard let refAnchor = anchors.first else {
                if let tcHint { placements.append((tcHint.clipId, tcHint.rawStart, 1.0, .timecode, 0, nil)); continue }
                report.failures.append((bearer.id, mode == .auto && refTCCarrier == nil
                    ? "Reference has no source timecode or audio." : "Reference clip has no audio."))
                continue
            }
            guard let liveBearer = liveClip(bearer.id) else {
                if let tcHint { placements.append((tcHint.clipId, tcHint.rawStart, 1.0, .timecode, 0, nil)); continue }
                report.failures.append((bearer.id, "Clip not found.")); continue
            }
            let clip = AudioClip(
                clipId: bearer.id, samples: env.samples, speed: liveBearer.speed,
                mediaRef: liveBearer.mediaRef, trimStartFrame: liveBearer.trimStartFrame)
            candidates.append((clip, await match(refAnchor, clip), tcHint?.rawStart))
        }

        // Place the most confident match first; weaker clips may align better to those placed after.
        candidates.sort { ($0.direct?.confidence ?? 0) > ($1.direct?.confidence ?? 0) }
        for (clip, direct, tcRawStart) in candidates {
            try Task.checkCancellation()
            var best = direct
            for anchor in anchors.dropFirst() {
                if let hit = await match(anchor, clip), hit.confidence > (best?.confidence ?? 0) { best = hit }
            }
            guard let best else {
                if let tcRawStart {
                    placements.append((clip.clipId, tcRawStart, 1.0, .timecode, 0, nil))
                    anchors.append((tcRawStart, clip))
                    continue
                }
                report.failures.append((clip.clipId, "No confident alignment — clips may not overlap.")); continue
            }
            placements.append((clip.clipId, best.rawStart, best.confidence, .audio, best.driftRatio, best.retimedSpeed))
            anchors.append((best.rawStart, clip))
        }
        try Task.checkCancellation()

        // Validate moves before applying group shift; overlap results are preserved.
        var allMoves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        var movedIds = Set<String>()
        var plannedDurations: [String: Int] = [:]
        func plannedDuration(_ clipId: String) -> Int {
            if let duration = plannedDurations[clipId] { return duration }
            return liveClip(clipId)?.durationFrames ?? 0
        }
        func queueMove(of clipId: String, toFrame rawStart: Int) -> String? {
            guard let loc = findClip(id: clipId) else { return "Clip not found." }
            let delta = rawStart - timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
            var moves = [(clipId: clipId, toTrack: loc.trackIndex, toFrame: rawStart)]
            // Include all linked partners, regardless of current positions, to avoid splitting pairs when shifting.
            for pid in linkedPartnerIds(of: clipId) where pid != referenceClipId {
                guard let pLoc = findClip(id: pid) else { continue }
                let pClip = timeline.tracks[pLoc.trackIndex].clips[pLoc.clipIndex]
                moves.append((clipId: pid, toTrack: pLoc.trackIndex, toFrame: pClip.startFrame + delta))
            }
            if clipId != referenceClipId,
               moveWouldClobberReference(moves, referenceClipId: referenceClipId, durationOf: plannedDuration) {
                return "Shares the reference's track — move it to its own track first."
            }
            if movesOverlapQueued(moves, allMoves, durationOf: plannedDuration) {
                return "Overlaps another clip being synced on the same track."
            }
            for move in moves where movedIds.insert(move.clipId).inserted { allMoves.append(move) }
            return nil
        }

        var accepted: [(clipId: String, rawStart: Int, confidence: Double, method: SyncMethod, currentStart: Int)] = []
        var retimes: [(ids: [String], speed: Double, driftPpm: Double, bearerId: String)] = []
        var stagedFailures: [(clipId: String, message: String)] = []
        var skippedRetimeBearers: [String] = []
        var shift = 0

        // A skipped retime shrinks footprints and can unblock other moves; requeue until stable.
        while true {
            allMoves.removeAll()
            movedIds.removeAll()
            plannedDurations.removeAll()
            accepted.removeAll()
            retimes.removeAll()
            stagedFailures.removeAll()

            for p in placements {
                guard let clip = liveClip(p.clipId) else { stagedFailures.append((p.clipId, "Clip not found.")); continue }
                var retime: (ids: [String], speed: Double)?
                if let speed = p.retimedSpeed, speed != clip.speed, !skippedRetimeBearers.contains(p.clipId) {
                    let unitIds = [p.clipId] + linkedPartnerIds(of: p.clipId).filter { $0 != referenceClipId }
                    retime = (unitIds, speed)
                    for id in unitIds {
                        guard let unitClip = liveClip(id) else { continue }
                        plannedDurations[id] = Self.retimedDurationFrames(
                            durationFrames: unitClip.durationFrames, speed: unitClip.speed, newSpeed: speed)
                    }
                }
                if let failure = queueMove(of: p.clipId, toFrame: p.rawStart) {
                    for id in retime?.ids ?? [] { plannedDurations.removeValue(forKey: id) }
                    stagedFailures.append((p.clipId, failure)); continue
                }
                accepted.append((p.clipId, p.rawStart, p.confidence, p.method, clip.startFrame))
                if let retime { retimes.append((retime.ids, retime.speed, p.driftRatio * 1_000_000, p.clipId)) }
            }

            // Shift right if any accepted move (partners included) starts before frame 0.
            shift = max(0, -(allMoves.map(\.toFrame).min() ?? 0))
            if shift > 0 {
                let failure = liveClip(referenceClipId).map { queueMove(of: referenceClipId, toFrame: $0.startFrame) }
                    ?? "Reference clip unavailable."
                if let failure {
                    report.shiftedFrames = shift
                    report.failures.append(contentsOf: stagedFailures)
                    report.failures.append(contentsOf: accepted.map { ($0.clipId, failure) })
                    return report
                }
            }

            let blockedBearers = retimes.filter { retime in
                retime.ids.contains { id in
                    guard let move = allMoves.first(where: { $0.clipId == id }),
                          let newDuration = plannedDurations[id] else { return false }
                    return retimeGrowthWouldClobberUnmovedClip(
                        clipId: id, finalStart: move.toFrame + shift, newDuration: newDuration, movedIds: movedIds)
                }
            }.map(\.bearerId)
            guard !blockedBearers.isEmpty else { break }
            skippedRetimeBearers.append(contentsOf: blockedBearers)
        }

        report.shiftedFrames = shift
        report.failures.append(contentsOf: stagedFailures)
        report.synced = accepted.map { ($0.clipId, $0.rawStart + shift - $0.currentStart, $0.confidence, $0.method) }
        let acceptedIds = Set(accepted.map(\.clipId))
        report.retimeSkipped = skippedRetimeBearers.filter(acceptedIds.contains).map {
            ($0, "Drift correction skipped — it would overwrite an adjacent clip.")
        }
        report.retimed = retimes.map { ($0.bearerId, $0.driftPpm) }

        let retimedIds = Set(retimes.flatMap(\.ids))
        let moves = allMoves.compactMap { move -> (clipId: String, toTrack: Int, toFrame: Int)? in
            guard let clip = liveClip(move.clipId),
                  move.toFrame + shift != clip.startFrame || retimedIds.contains(move.clipId)
            else { return nil }
            return (move.clipId, move.toTrack, move.toFrame + shift)
        }
        if !moves.isEmpty || !retimes.isEmpty {
            try Task.checkCancellation()
            let apply: @MainActor () -> Void = { [self] in
                for retime in retimes { commitClipSpeed(ids: retime.ids, newSpeed: retime.speed, ripple: false) }
                if !moves.isEmpty { moveClips(moves) }
            }
            if let mutation {
                try await mutation(apply)
            } else {
                undo.perform("Synchronize", apply)
            }
        }
        return report
    }

    func syncSelection() -> (referenceClipId: String, targetClipIds: [String])? {
        let selected = timeline.tracks.flatMap(\.clips)
            .filter { selectedClipIds.contains($0.id) && $0.multicamGroupId == nil }
        var units: [String: [Clip]] = [:]
        for clip in selected { units[clip.linkGroupId ?? clip.id, default: []].append(clip) }

        // Prefer the audio bearer; a video clip with no audio can still sync by timecode.
        var bearers: [(unit: [Clip], clip: Clip)] = []
        for unit in units.values {
            guard let clip = unit.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unit.first(where: { captionCanTranscribe($0) })
                ?? unit.first(where: { $0.mediaType == .video }) else { continue }
            bearers.append((unit, clip))
        }
        guard bearers.count >= 2 else { return nil }

        func rank(_ b: (unit: [Clip], clip: Clip)) -> (Int, Int, Int) {
            (b.unit.contains { $0.linkGroupId != nil } ? 0 : 1,
             b.unit.contains { $0.mediaType.isVisual } ? 0 : 1,
             b.unit.map(\.startFrame).min() ?? 0)
        }
        let ordered = bearers.sorted { rank($0) < rank($1) }
        let targets = ordered.dropFirst().sorted { $0.clip.startFrame < $1.clip.startFrame }.map(\.clip.id)
        return (ordered[0].clip.id, targets)
    }

    func retimeGrowthWouldClobberUnmovedClip(
        clipId: String, finalStart: Int, newDuration: Int, movedIds: Set<String>
    ) -> Bool {
        guard let loc = findClip(id: clipId) else { return false }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let grownStart = finalStart + clip.durationFrames
        let grownEnd = finalStart + newDuration
        guard grownEnd > grownStart else { return false }
        return timeline.tracks[loc.trackIndex].clips.contains {
            $0.id != clip.id && !movedIds.contains($0.id)
                && $0.startFrame < grownEnd && $0.endFrame > grownStart
        }
    }

    private func moveWouldClobberReference(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)], referenceClipId: String,
        durationOf duration: (String) -> Int
    ) -> Bool {
        guard let refLoc = findClip(id: referenceClipId) else { return false }
        let ref = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
        for move in moves where move.toTrack == refLoc.trackIndex {
            if move.toFrame < ref.endFrame && ref.startFrame < move.toFrame + duration(move.clipId) { return true }
        }
        return false
    }

    private func movesOverlapQueued(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)],
        _ queued: [(clipId: String, toTrack: Int, toFrame: Int)],
        durationOf duration: (String) -> Int
    ) -> Bool {
        for move in moves {
            let end = move.toFrame + duration(move.clipId)
            for other in queued where other.toTrack == move.toTrack {
                if move.toFrame < other.toFrame + duration(other.clipId) && other.toFrame < end { return true }
            }
        }
        return false
    }

    private func envelope(of clip: Clip, fps: Double) async -> AudioEnvelope? {
        guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { return nil }
        let start = Double(clip.trimStartFrame) / fps
        let end = start + Double(clip.durationFrames) * max(clip.speed, SyncDefaults.minSpeed) / fps
        return try? await AudioEnvelopeExtractor.extract(from: url, range: start...max(start + AudioEnvelopeExtractor.hopSeconds, end))
    }
}
