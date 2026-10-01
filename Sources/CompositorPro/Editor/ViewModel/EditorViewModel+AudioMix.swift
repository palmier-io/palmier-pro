import Foundation

enum AudioMixError: Error, Equatable, CustomStringConvertible {
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
                        updated.upsertKeyframe(
                            in: \Clip.volumeTrack,
                            frame: from + sample.frameOffset,
                            value: max(0, index == 0 ? sample.outgoing : sample.incoming)
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

    /// Writes a dialogue-aware volume envelope on a bed clip, as one undo step.
    ///
    /// `sources` defaults to every other audio clip overlapping the bed. Speech spans come from
    /// cached voice-activity analysis; when detection is unavailable the whole source clip is used
    /// as one span and the receipt says so, so the caller can judge the result.
    @discardableResult
    func duckAudio(
        bedId: String,
        sourceIds: [String]? = nil,
        duckDb: Double = DuckingPlan.Parameters.default.duckDb,
        attackFrames: Int = DuckingPlan.Parameters.default.attackFrames,
        holdFrames: Int = DuckingPlan.Parameters.default.holdFrames,
        releaseFrames: Int = DuckingPlan.Parameters.default.releaseFrames,
        mergeGapFrames: Int = DuckingPlan.Parameters.default.mergeGapFrames,
        overwrite: Bool = false
    ) async throws -> DuckingReceipt {
        guard let bedLocation = findClip(id: bedId) else { throw AudioMixError.unknownClip(bedId) }
        let bed = timeline.tracks[bedLocation.trackIndex].clips[bedLocation.clipIndex]
        guard bed.mediaType == .audio else { throw AudioMixError.notAudio(bedId) }
        if bed.volumeTrack?.isActive == true, !overwrite {
            throw AudioMixError.alreadyHasVolumeAutomation(clipId: bedId)
        }

        let sources = try sourceClips(dialogueOverlapping: bed, explicitIds: sourceIds)
        let spans = try await speechSpans(for: sources)
        guard !spans.isEmpty else { throw AudioMixError.noDialogueOverlap }

        let parameters = DuckingPlan.Parameters(
            duckDb: duckDb, attackFrames: attackFrames, holdFrames: holdFrames,
            releaseFrames: releaseFrames, mergeGapFrames: mergeGapFrames
        )
        let plan = try DuckingPlan.plan(
            bedStartFrame: bed.startFrame,
            bedDurationFrames: bed.durationFrames,
            speechSpans: spans.map { $0.timeline },
            parameters: parameters
        )
        guard !plan.isEmpty else { throw AudioMixError.noDialogueOverlap }

        // Revalidate: speech detection awaited, so the bed may have moved or gone.
        guard let current = findClip(id: bedId),
              timeline.tracks[current.trackIndex].clips[current.clipIndex].startFrame == bed.startFrame,
              timeline.tracks[current.trackIndex].clips[current.clipIndex].durationFrames == bed.durationFrames
        else {
            throw AudioMixError.unknownClip(bedId)
        }
        let location = current
        withTimelineSwap(actionName: "Ducking") {
            var updated = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            if overwrite { updated.volumeTrack = nil }
            for keyframe in plan.keyframes {
                updated.volumeTrack = updated.volumeTrack ?? KeyframeTrack<Double>()
                updated.volumeTrack!.upsert(keyframe)
            }
            timeline.tracks[location.trackIndex].clips[location.clipIndex] = updated
        }
        onProjectCheckpointRequired?()
        return DuckingReceipt(
            bedClipId: bedId,
            duckedRanges: plan.windows,
            keyframesWritten: plan.keyframes.count,
            sourceClipIds: sources.map { $0.clip.id },
            duckDb: duckDb,
            usedWholeClipFallback: spans.contains { $0.wholeClipFallback },
            ignoredSpans: plan.ignoredSpans
        )
    }

    // MARK: - Speech spans

    private struct SourceClip {
        var clip: Clip
        var asset: MediaAsset
    }

    private struct SpeechSpan {
        var timeline: Range<Int>
        var wholeClipFallback: Bool
    }

    private func sourceClips(dialogueOverlapping bed: Clip, explicitIds: [String]?) throws -> [SourceClip] {
        if let explicitIds, !explicitIds.isEmpty {
            return try explicitIds.map { id in
                guard id != bed.id else { throw AudioMixError.bedIsItsOwnSource(clipId: id) }
                guard let location = findClip(id: id) else { throw AudioMixError.unknownClip(id) }
                let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
                guard clip.mediaType == .audio else { throw AudioMixError.notAudio(id) }
                guard let asset = mediaAssetsById[clip.mediaRef] else { throw AudioMixError.unknownClip(id) }
                return SourceClip(clip: clip, asset: asset)
            }
        }
        let candidates = timeline.tracks
            .flatMap(\.clips)
            .filter { $0.id != bed.id && $0.mediaType == .audio && $0.startFrame < bed.endFrame && $0.endFrame > bed.startFrame }
        guard !candidates.isEmpty else { throw AudioMixError.noDialogueOverlap }
        return candidates.compactMap { clip in
            mediaAssetsById[clip.mediaRef].map { SourceClip(clip: clip, asset: $0) }
        }
    }

    /// Voice-activity spans mapped into timeline frames. Detection and file reads stay off the
    /// main actor; only the resulting frame ranges cross back.
    private func speechSpans(for sources: [SourceClip]) async throws -> [SpeechSpan] {
        let fps = Double(timeline.fps)
        guard fps > 0 else { return [] }
        let requests: [(clip: Clip, url: URL, mediaRef: String)] = sources.compactMap { source in
            return (source.clip, source.asset.url, source.asset.id)
        }
        let detected = await Task.detached(priority: .userInitiated) { () -> [Int: [Range<Int>]] in
            var result: [Int: [Range<Int>]] = [:]
            for (index, request) in requests.enumerated() {
                if let analysis = try? await VoiceActivity.analysis(
                    for: request.url, mediaRef: request.mediaRef
                ) {
                    result[index] = analysis.segments.map { span in
                        let lower = Int((span.start * fps).rounded())
                        let upper = Int((span.end * fps).rounded())
                        return lower ..< max(lower + 1, upper)
                    }
                }
            }
            return result
        }.value

        var spans: [SpeechSpan] = []
        for (index, request) in requests.enumerated() {
            let clip = request.clip
            let fallback = detected[index] == nil
            let sourceFrames = detected[index]
                ?? [0 ..< clip.timeMap.sourceFramesConsumed]
            spans.append(contentsOf: Self.timelineFrames(from: sourceFrames, clip: clip, fps: fps)
                .map { SpeechSpan(timeline: $0, wholeClipFallback: fallback) })
        }
        return spans
    }

    /// Source frames → absolute timeline frames through the clip's own mapping and start.
    nonisolated static func timelineFrames(
        from frames: [Range<Int>],
        clip: Clip,
        fps: Double
    ) -> [Range<Int>] {
        let map = clip.timeMap
        return frames.compactMap { span in
            let lower = clip.startFrame
                + map.timelineOffset(forSourceOffset: Double(span.lowerBound))
            let upper = clip.startFrame
                + map.timelineOffset(forSourceOffset: Double(span.upperBound))
            return lower < upper ? lower ..< upper : nil
        }
    }
}
