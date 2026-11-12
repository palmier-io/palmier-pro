import Foundation

enum AudioMixError: Error, LocalizedError, Equatable, CustomStringConvertible {
    case unknownClip(String)
    case notAudio(String)
    case sameClip
    case differentTracks
    case notAdjacent(gapFrames: Int)
    case durationTooLong(available: Int, requested: Int)
    case durationTooShort
    case edgesAlreadyFaded(clipId: String)
    case alreadyHasVolumeAutomation(clipId: String)
    case noDialogueOverlap
    case bedIsItsOwnSource(clipId: String)
    case noAudioInTimeline
    case sourceUnavailable(String)
    case staleState
    case duplicateSources

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unknownClip(let id): "Clip not found: \(id)."
        case .notAudio(let id): "Clip \(id) is not audio."
        case .sameClip: "Crossfade needs two different clips."
        case .differentTracks: "Crossfade needs both clips on the same track."
        case .notAdjacent(let gap): "Crossfade needs adjacent clips; there are \(gap) frames between them."
        case .durationTooLong(let available, let requested):
            "Crossfade of \(requested) frames exceeds the \(available) frames available at the cut."
        case .durationTooShort: "Crossfade needs at least 1 frame."
        case .edgesAlreadyFaded(let id):
            "Clip \(id) already has a fade on the edge the equal-power crossfade needs. "
                + "Clear it with set_clip_properties, or use the default curve."
        case .alreadyHasVolumeAutomation(let id):
            "Clip \(id) already has volume keyframes. Pass overwrite:true to replace them, "
                + "or animate a different clip."
        case .noDialogueOverlap: "No dialogue audio overlaps the bed, so there is nothing to duck under."
        case .bedIsItsOwnSource(let id): "Clip \(id) cannot duck under itself; list the dialogue clips as sources."
        case .noAudioInTimeline: "The timeline has no audio clips."
        case .sourceUnavailable(let id): "Audio source '\(id)' is unavailable or still processing."
        case .staleState: "Project, timeline, or audio sources changed during preparation. Retry with current state."
        case .duplicateSources: "Dialogue source IDs must be nonempty and unique."
        }
    }
}

extension EditorViewModel {
    struct AudioCrossfadeReceipt: Sendable, Equatable {
        var outgoingClipId: String
        var incomingClipId: String
        var cutFrame: Int
        var durationFrames: Int
        var curve: String
        var equalPowerSamples: Int
    }

    struct DuckingReceipt: Sendable, Equatable {
        var bedClipId: String
        var duckedRanges: [Range<Int>]
        var keyframesWritten: Int
        var sourceClipIds: [String]
        var duckDb: Double
        /// True when speech could not be detected and whole-clip spans were used instead.
        var usedWholeClipFallback: Bool
        var ignoredSpans: Int
        var changed: Bool
        var speechDetection: [String: String]
    }

    /// Crossfades two adjacent audio clips on one track, as one undo step. A `linear` or `smooth`
    /// curve uses the clips' own fade ramps so the UI keeps showing fade handles; `equalPower`
    /// writes a sampled volume envelope instead, because the fade model cannot hold perceived
    /// loudness through the overlap.
    @discardableResult
    func crossfadeAudio(
        outgoingId: String,
        incomingId: String,
        durationFrames: Int,
        curve: String = "smooth"
    ) throws -> AudioCrossfadeReceipt {
        guard outgoingId != incomingId else { throw AudioMixError.sameClip }
        guard durationFrames >= 1 else { throw AudioMixError.durationTooShort }
        let curve = curve.lowercased()
        guard ["linear", "smooth", "equalpower"].contains(curve) else {
            throw ToolError("curve must be one of: linear, smooth, equalPower.")
        }
        guard let outgoingLocation = findClip(id: outgoingId) else {
            throw AudioMixError.unknownClip(outgoingId)
        }
        guard let incomingLocation = findClip(id: incomingId) else {
            throw AudioMixError.unknownClip(incomingId)
        }
        guard outgoingLocation.trackIndex == incomingLocation.trackIndex else {
            throw AudioMixError.differentTracks
        }
        let trackIndex = outgoingLocation.trackIndex
        let track = timeline.tracks[trackIndex]
        guard track.type == .audio else { throw AudioMixError.notAudio(track.id) }
        let outgoing = track.clips[outgoingLocation.clipIndex]
        let incoming = track.clips[incomingLocation.clipIndex]
        guard outgoing.mediaType == .audio else { throw AudioMixError.notAudio(outgoingId) }
        guard incoming.mediaType == .audio else { throw AudioMixError.notAudio(incomingId) }

        let cut = outgoing.endFrame
        let ordered = outgoing.startFrame <= incoming.startFrame
            ? (outgoing, incoming) : (incoming, outgoing)
        let gap = ordered.1.startFrame - ordered.0.endFrame
        guard gap == 0 else { throw AudioMixError.notAdjacent(gapFrames: gap) }

        let available = min(ordered.0.durationFrames, ordered.1.durationFrames)
        guard durationFrames <= available else {
            throw AudioMixError.durationTooLong(available: available, requested: durationFrames)
        }
        if curve == "equalpower" {
            if ordered.0.fadeOutFrames > 0 { throw AudioMixError.edgesAlreadyFaded(clipId: ordered.0.id) }
            if ordered.1.fadeInFrames > 0 { throw AudioMixError.edgesAlreadyFaded(clipId: ordered.1.id) }
        }

        var sampleCount = 0
        withTimelineSwap(actionName: "Audio Crossfade") {
            let samples = AudioFadeCurve.equalPowerSamples(frames: durationFrames)
            sampleCount = samples.count
            for (index, clip) in [outgoingLocation, incomingLocation].enumerated() {
                var updated = timeline.tracks[clip.trackIndex].clips[clip.clipIndex]
                if curve == "equalpower" {
                    let from = updated.startFrame + updated.durationFrames - durationFrames
                    for sample in samples {
                        // The clip volume track holds decibels, so the equal-power gain
                        // samples have to be converted before they are written.
                        let gain = max(0, index == 0 ? sample.outgoing : sample.incoming)
                        updated.upsertKeyframe(
                            in: \Clip.volumeTrack,
                            frame: from + sample.frameOffset,
                            value: VolumeScale.dbFromLinear(gain)
                        )
                    }
                } else {
                    let interpolation: Interpolation = curve == "linear" ? .linear : .smooth
                    if index == 0 {
                        updated.setFade(.right, frames: durationFrames)
                        updated.setFadeInterpolation(.right, interpolation)
                    } else {
                        updated.setFade(.left, frames: durationFrames)
                        updated.setFadeInterpolation(.left, interpolation)
                    }
                }
                timeline.tracks[clip.trackIndex].clips[clip.clipIndex] = updated
            }
        }
        onProjectCheckpointRequired?()
        return AudioCrossfadeReceipt(
            outgoingClipId: ordered.0.id,
            incomingClipId: ordered.1.id,
            cutFrame: cut,
            durationFrames: durationFrames,
            curve: curve == "equalpower" ? "equalPower" : curve,
            equalPowerSamples: curve == "equalpower" ? sampleCount : 0
        )
    }

    @discardableResult
    func duckAudio(
        bedId: String,
        sourceIds: [String]? = nil,
        duckDb: Double = DuckingPlan.Parameters.default.duckDb,
        attackFrames: Int = DuckingPlan.Parameters.default.attackFrames,
        holdFrames: Int = DuckingPlan.Parameters.default.holdFrames,
        releaseFrames: Int = DuckingPlan.Parameters.default.releaseFrames,
        mergeGapFrames: Int = DuckingPlan.Parameters.default.mergeGapFrames,
        overwrite: Bool = false,
        allowWholeClipFallback: Bool = false,
        resolveSpeech: @Sendable ([AudioSpeechTiming.Source], Int, Bool) async throws -> AudioSpeechTiming.Result = {
            try await AudioSpeechTiming.analyze($0, fps: $1, allowWholeClipFallback: $2)
        }
    ) async throws -> DuckingReceipt {
        try await projectPackageCoordinator.withIntent { _ in
        try Task.checkCancellation()
        let snapshot = timeline
        let revision = visualReviewRevision
        guard let bedLocation = findClip(id: bedId) else { throw AudioMixError.unknownClip(bedId) }
        let bed = timeline.tracks[bedLocation.trackIndex].clips[bedLocation.clipIndex]
        guard bed.mediaType == .audio, timeline.tracks[bedLocation.trackIndex].type == .audio,
              !timeline.tracks[bedLocation.trackIndex].muted else { throw AudioMixError.notAudio(bedId) }
        let parameters = DuckingPlan.Parameters(
            duckDb: duckDb, attackFrames: attackFrames, holdFrames: holdFrames,
            releaseFrames: releaseFrames, mergeGapFrames: mergeGapFrames
        )
        _ = try DuckingPlan.plan(bedStartFrame: bed.startFrame, bedDurationFrames: bed.durationFrames,
                                speechSpans: [], parameters: parameters)
        if duckDb == 0 {
            return DuckingReceipt(bedClipId: bedId, duckedRanges: [], keyframesWritten: 0, sourceClipIds: [],
                                  duckDb: 0, usedWholeClipFallback: false, ignoredSpans: 0,
                                  changed: false, speechDetection: [:])
        }
        if bed.volumeTrack?.isActive == true, !overwrite {
            throw AudioMixError.alreadyHasVolumeAutomation(clipId: bedId)
        }
        guard let bedAsset = mediaAssetsById[bed.mediaRef], bedAsset.generationStatus == .none,
              (allowWholeClipFallback || !missingMediaRefs.contains(bed.mediaRef)),
              !unprocessableMediaRefs.contains(bed.mediaRef) else {
            throw AudioMixError.sourceUnavailable(bed.mediaRef)
        }
        let bedURL = bedAsset.url
        let sources = try sourceClips(dialogueOverlapping: bed, explicitIds: sourceIds, allowAbsent: allowWholeClipFallback)
        let bedVersions = try await LoudnessAnalyzer.sourceVersions(for: [bedURL])
        let spans = try await resolveSpeech(sources.map { .init(clip: $0.clip, url: $0.url) }, snapshot.fps, allowWholeClipFallback)
        try Task.checkCancellation()
        guard !spans.ranges.isEmpty else { throw AudioMixError.noDialogueOverlap }
        let plan = try DuckingPlan.plan(
            bedStartFrame: bed.startFrame,
            bedDurationFrames: bed.durationFrames,
            speechSpans: spans.ranges,
            parameters: parameters
        )
        guard !plan.isEmpty else { throw AudioMixError.noDialogueOverlap }
        try await LoudnessAnalyzer.validateSourceVersions(bedVersions)
        try await LoudnessAnalyzer.validateSourceVersions(spans.sourceVersions)
        try Task.checkCancellation()
        guard !projectPackageCoordinator.isClosing, visualReviewRevision == revision, timeline == snapshot,
              activeTimelineId == snapshot.id, mediaAssetsById[bed.mediaRef] === bedAsset, bedAsset.url == bedURL,
              bedAsset.generationStatus == .none, sources.allSatisfy({ source in
                  mediaAssetsById[source.clip.mediaRef] === source.asset && source.asset.url == source.url
                      && source.asset.generationStatus == .none && (allowWholeClipFallback || !missingMediaRefs.contains(source.clip.mediaRef))
                      && !unprocessableMediaRefs.contains(source.clip.mediaRef)
              }) else {
            throw AudioMixError.staleState
        }
        let track = KeyframeTrack(keyframes: plan.keyframes)
        let changed = bed.volumeTrack != track
        if changed {
            withTimelineSwap(actionName: L10n.string("Ducking")) {
                timeline.tracks[bedLocation.trackIndex].clips[bedLocation.clipIndex].volumeTrack = track
            }
            onProjectCheckpointRequired?()
        }
        return DuckingReceipt(
            bedClipId: bedId,
            duckedRanges: plan.windows,
            keyframesWritten: plan.keyframes.count,
            sourceClipIds: sources.map { $0.clip.id },
            duckDb: duckDb,
            usedWholeClipFallback: spans.usedWholeClipFallback,
            ignoredSpans: plan.ignoredSpans,
            changed: changed,
            speechDetection: Dictionary(uniqueKeysWithValues: spans.timings.map { ($0.clipId, $0.method.rawValue) })
        )
        }
    }

    // MARK: - Speech spans

    private struct SourceClip {
        var clip: Clip
        var asset: MediaAsset
        var url: URL
    }

    private func sourceClips(dialogueOverlapping bed: Clip, explicitIds: [String]?, allowAbsent: Bool = false) throws -> [SourceClip] {
        if let explicitIds {
            guard !explicitIds.isEmpty, Set(explicitIds).count == explicitIds.count else { throw AudioMixError.duplicateSources }
            return try explicitIds.map { id in
                guard id != bed.id else { throw AudioMixError.bedIsItsOwnSource(clipId: id) }
                guard let location = findClip(id: id) else { throw AudioMixError.unknownClip(id) }
                let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
                guard clip.mediaType == .audio, !timeline.tracks[location.trackIndex].muted,
                      clip.sourceClipType != .sequence else { throw AudioMixError.notAudio(id) }
                return try audioSource(for: clip, allowAbsent: allowAbsent)
            }
        }
        let candidates = timeline.tracks
            .filter { $0.type == .audio && !$0.muted }
            .flatMap(\.clips)
            .filter { $0.id != bed.id && $0.mediaType == .audio && $0.startFrame < bed.endFrame && $0.endFrame > bed.startFrame }
        guard !candidates.isEmpty else { throw AudioMixError.noDialogueOverlap }
        return try candidates.map { try audioSource(for: $0, allowAbsent: allowAbsent) }
    }
    private func audioSource(for clip: Clip, allowAbsent: Bool = false) throws -> SourceClip {
        guard clip.sourceClipType != .sequence, let asset = mediaAssetsById[clip.mediaRef],
              asset.generationStatus == .none, (allowAbsent || !missingMediaRefs.contains(clip.mediaRef)),
              !unprocessableMediaRefs.contains(clip.mediaRef) else {
            throw AudioMixError.sourceUnavailable(clip.mediaRef)
        }
        return SourceClip(clip: clip, asset: asset, url: asset.url)
    }

    /// Source frames → absolute timeline frames through the clip's own mapping and start.
    nonisolated static func timelineFrames(
        from frames: [Range<Int>],
        clip: Clip,
        fps: Double
    ) -> [Range<Int>] {
        return frames.compactMap { span in
            clip.timelineRange(sourceStartFrame: Double(span.lowerBound), sourceEndFrame: Double(span.upperBound))
        }
    }
}
