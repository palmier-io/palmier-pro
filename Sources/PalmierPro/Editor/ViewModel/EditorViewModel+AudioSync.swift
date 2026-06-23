import Foundation

extension EditorViewModel {
    struct AudioSyncBatchReport: Sendable {
        var synced: [(clipId: String, offsetFrames: Int, confidence: Double)] = []
        var failures: [(clipId: String, message: String)] = []
    }

    enum AudioSyncDefaults {
        static let searchWindowSeconds: Double = 30
        static let minConfidence: Double = 0.5
        static let minSpeed: Double = 0.0001
    }

    @discardableResult
    func syncAudio(
        referenceClipId: String,
        targetClipIds: [String],
        searchWindowSeconds: Double = AudioSyncDefaults.searchWindowSeconds,
        minConfidence: Double = AudioSyncDefaults.minConfidence
    ) async -> AudioSyncBatchReport {
        let fps = Double(timeline.fps)
        let targets = targetClipIds.filter { $0 != referenceClipId }

        guard fps > 0, let refLoc = findClip(id: referenceClipId) else {
            return AudioSyncBatchReport(failures: targets.map { ($0, "Reference clip unavailable.") })
        }
        let refClip = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
        guard let refEnv = await envelope(of: refClip, fps: fps), !refEnv.samples.isEmpty else {
            return AudioSyncBatchReport(failures: targets.map { ($0, "Reference clip has no audio.") })
        }
        let maxLag = max(1, Int((searchWindowSeconds / AudioEnvelopeExtractor.hopSeconds).rounded()))
        let refSamples = refEnv.samples
        var report = AudioSyncBatchReport()
        let refGroup = refClip.linkGroupId

        var bearerIds: [String] = []
        var seenGroups = Set<String>()
        for id in targets {
            guard let loc = findClip(id: id) else { report.failures.append((id, "Clip not found.")); continue }
            guard let group = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].linkGroupId else {
                bearerIds.append(id); continue
            }
            if group == refGroup {
                report.failures.append((id, "Clip is linked to the reference — they already move together.")); continue
            }
            guard seenGroups.insert(group).inserted else { continue }
            let unit = timeline.tracks.flatMap(\.clips).filter { $0.linkGroupId == group }
            guard let bearer = unit.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unit.first(where: { captionCanTranscribe($0) }) else {
                report.failures.append((id, "Clip has no audio.")); continue
            }
            bearerIds.append(bearer.id)
        }

        var allMoves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        var movedIds = Set<String>()

        for id in bearerIds {
            if movedIds.contains(id) { continue }
            guard let loc = findClip(id: id) else { report.failures.append((id, "Clip not found.")); continue }
            let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard let env = await envelope(of: clip, fps: fps), !env.samples.isEmpty else {
                report.failures.append((id, "Clip has no audio.")); continue
            }
            let match = await Task.detached(priority: .userInitiated) {
                AudioSyncCorrelator.correlate(reference: refSamples, target: env.samples, maxLagHops: maxLag)
            }.value
            guard let refLoc = findClip(id: referenceClipId), let loc = findClip(id: id) else {
                report.failures.append((id, "Clip not found.")); continue
            }
            let refClip = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
            let target = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard let match, match.confidence >= minConfidence else {
                report.failures.append((id, "No confident alignment — clips may not overlap.")); continue
            }
            let lagFrames = Double(match.lagHops) * AudioEnvelopeExtractor.hopSeconds * fps / max(refClip.speed, AudioSyncDefaults.minSpeed)
            let rawStart = Int((Double(refClip.startFrame) + lagFrames).rounded())
            guard rawStart >= 0 else { report.failures.append((id, "Alignment falls before the timeline start.")); continue }
            let offset = rawStart - target.startFrame

            if offset != 0 {
                var moves = [(clipId: id, toTrack: loc.trackIndex, toFrame: rawStart)]
                for pm in partnerMoves(forMoveOf: id, toFrame: rawStart) where pm.clipId != referenceClipId {
                    if let pLoc = findClip(id: pm.clipId) {
                        moves.append((clipId: pm.clipId, toTrack: pLoc.trackIndex, toFrame: pm.toFrame))
                    }
                }
                if moveWouldClobberReference(moves, referenceClipId: referenceClipId) {
                    report.failures.append((id, "Shares the reference's track — move it to its own track first.")); continue
                }
                if movesOverlapQueued(moves, allMoves) {
                    report.failures.append((id, "Overlaps another clip being synced on the same track.")); continue
                }
                for move in moves where movedIds.insert(move.clipId).inserted { allMoves.append(move) }
            }
            report.synced.append((id, offset, match.confidence))
        }

        if !allMoves.isEmpty {
            undoManager?.beginUndoGrouping()
            moveClips(allMoves)
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Synchronize")
        }
        return report
    }

    func audioSyncSelection() -> (referenceClipId: String, targetClipIds: [String])? {
        let selected = timeline.tracks.flatMap(\.clips).filter { selectedClipIds.contains($0.id) }
        var units: [String: [Clip]] = [:]
        for clip in selected { units[clip.linkGroupId ?? clip.id, default: []].append(clip) }

        // Skip units with no transcribable audio (text/image/etc.) rather than
        // suppressing sync for the whole selection.
        var bearers: [(unit: [Clip], clip: Clip)] = []
        for unit in units.values {
            guard let clip = unit.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unit.first(where: { captionCanTranscribe($0) }) else { continue }
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

    private func moveWouldClobberReference(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)], referenceClipId: String
    ) -> Bool {
        guard let refLoc = findClip(id: referenceClipId) else { return false }
        let ref = timeline.tracks[refLoc.trackIndex].clips[refLoc.clipIndex]
        for move in moves where move.toTrack == refLoc.trackIndex {
            guard let loc = findClip(id: move.clipId) else { continue }
            let duration = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames
            if move.toFrame < ref.endFrame && ref.startFrame < move.toFrame + duration { return true }
        }
        return false
    }

    private func movesOverlapQueued(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)],
        _ queued: [(clipId: String, toTrack: Int, toFrame: Int)]
    ) -> Bool {
        func duration(_ clipId: String) -> Int {
            guard let loc = findClip(id: clipId) else { return 0 }
            return timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames
        }
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
        let end = start + Double(clip.durationFrames) * max(clip.speed, AudioSyncDefaults.minSpeed) / fps
        return try? await AudioEnvelopeExtractor.extract(from: url, range: start...max(start + AudioEnvelopeExtractor.hopSeconds, end))
    }
}
