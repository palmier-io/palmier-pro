import Foundation

extension EditorViewModel {
    struct ValidatedTransition {
        let outgoing: Clip
        let incoming: Clip
        let trackIndex: Int
        let boundary: Int
        let half: Int
        let audioFade: Int
    }

    func validateTransition(
        outgoingId: String,
        incomingId: String,
        type: TransitionType,
        direction: TransitionDirection?,
        durationFrames: Int
    ) throws -> ValidatedTransition {
        guard durationFrames >= 2 else { throw TransitionValidationError.invalidDuration }
        if type == .slide || type == .push {
            guard let direction, TransitionDirection.allCases.contains(direction) else {
                throw TransitionValidationError.directionRequired
            }
        } else if direction != nil {
            throw TransitionValidationError.directionForbidden
        }
        guard let outgoingLoc = findClip(id: outgoingId),
              let incomingLoc = findClip(id: incomingId)
        else {
            throw TransitionValidationError.unknownClip(findClip(id: outgoingId) == nil ? outgoingId : incomingId)
        }
        guard outgoingLoc.trackIndex == incomingLoc.trackIndex else {
            throw TransitionValidationError.differentTracks
        }
        let track = timeline.tracks[outgoingLoc.trackIndex]
        let outgoing = track.clips[outgoingLoc.clipIndex]
        let incoming = track.clips[incomingLoc.clipIndex]
        guard incoming.startFrame == outgoing.endFrame else { throw TransitionValidationError.notAdjacent }
        for clip in [outgoing, incoming] {
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw TransitionValidationError.unsupportedMedia(clip.mediaType.rawValue)
            }
            guard clip.multicamGroupId == nil else { throw TransitionValidationError.multicam }
        }
        let maximum = min(outgoing.durationFrames, incoming.durationFrames)
        guard durationFrames <= maximum else {
            throw TransitionValidationError.durationTooLong(maximum: maximum)
        }
        if timeline.transitions.contains(where: {
            $0.outgoingClipId == outgoingId || $0.incomingClipId == incomingId
        }) {
            throw TransitionValidationError.existingTransition
        }
        switch type {
        case .dissolve, .dipToBlack:
            for clip in [outgoing, incoming] where clip.opacityTrack?.isActive == true {
                throw TransitionValidationError.conflictingKeyframes(clip.id)
            }
        case .slide:
            break
        case .push:
            guard outgoing.positionTrack?.isActive != true else {
                throw TransitionValidationError.conflictingKeyframes(outgoing.id)
            }
        }
        if type != .dipToBlack {
            guard incoming.speed.isFinite, incoming.speed > 0 else {
                throw TransitionValidationError.insufficientHandles(frames: durationFrames / 2)
            }
            let need = Int((Double(durationFrames / 2) * incoming.speed).rounded())
            guard incoming.trimStartFrame >= need else {
                throw TransitionValidationError.insufficientHandles(frames: need)
            }
        }
        return ValidatedTransition(
            outgoing: outgoing,
            incoming: incoming,
            trackIndex: outgoingLoc.trackIndex,
            boundary: incoming.startFrame,
            half: durationFrames / 2,
            audioFade: durationFrames / 2
        )
    }

    @discardableResult
    func applyTransition(
        outgoingId: String,
        incomingId: String,
        type: TransitionType,
        direction: TransitionDirection?,
        durationFrames: Int
    ) throws -> TimelineTransition {
        let plan = try validateTransition(
            outgoingId: outgoingId, incomingId: incomingId,
            type: type, direction: direction, durationFrames: durationFrames
        )
        let outgoingAudioId = linkedAudioClipId(for: plan.outgoing)
        let incomingAudioId = linkedAudioClipId(for: plan.incoming)

        var record = TimelineTransition(
            outgoingClipId: plan.outgoing.id,
            incomingClipId: plan.incoming.id,
            trackId: timeline.tracks[plan.trackIndex].id,
            type: type,
            direction: direction,
            durationFrames: durationFrames
        )

        // Resolve everything that can fail before mutating, so a failed apply leaves no trace.
        let overlayAsset: MediaAsset? = type == .dipToBlack
            ? nil
            : mediaAssetsById[plan.incoming.mediaRef]
        if type != .dipToBlack, overlayAsset == nil {
            throw TransitionValidationError.unknownClip(plan.incoming.mediaRef)
        }

        withTimelineSwap(actionName: "Apply Transition") {
            if type == .dipToBlack {
                setOpacityTrack(clipId: plan.outgoing.id, rows: [
                    (plan.outgoing.durationFrames - plan.half, plan.outgoing.opacity),
                    (plan.outgoing.durationFrames, 0),
                ])
                setOpacityTrack(clipId: plan.incoming.id, rows: [
                    (0, 0),
                    (plan.half, plan.incoming.opacity),
                ])
            } else {
                let overlayIndex = plan.trackIndex
                timeline.tracks.insert(Track(type: .video), at: overlayIndex)
                let asset = overlayAsset!
                let overlayStart = plan.boundary - plan.half
                let trimStart = plan.incoming.trimStartFrame - Int((Double(plan.half) * plan.incoming.speed).rounded())
                let placed = placeClip(
                    asset: asset,
                    trackIndex: overlayIndex,
                    startFrame: overlayStart,
                    durationFrames: durationFrames,
                    trimStartFrame: trimStart
                )
                guard let overlayId = placed.first else { return }
                if let overlayLoc = findClip(id: overlayId) {
                    var overlay = timeline.tracks[overlayLoc.trackIndex].clips[overlayLoc.clipIndex]
                    overlay.transform = plan.incoming.transform
                    overlay.crop = plan.incoming.crop
                    overlay.effects = plan.incoming.effects
                    timeline.tracks[overlayLoc.trackIndex].clips[overlayLoc.clipIndex] = overlay
                }
                record.overlayClipIds = placed
                switch type {
                case .dissolve:
                    setOpacityTrack(clipId: overlayId, rows: [(0, 0), (durationFrames, 1)])
                case .slide:
                    let from = slideEntryPoint(direction: direction ?? .left)
                    setPositionTrack(clipId: overlayId, rows: [(0, from), (durationFrames, (0, 0))])
                case .push:
                    let from = slideEntryPoint(direction: direction ?? .left)
                    setPositionTrack(clipId: overlayId, rows: [(0, from), (durationFrames, (0, 0))])
                    setPositionTrack(clipId: plan.outgoing.id, rows: [
                        (plan.outgoing.durationFrames - durationFrames, (0, 0)),
                        (plan.outgoing.durationFrames, slideExitPoint(direction: direction ?? .left)),
                    ])
                case .dipToBlack:
                    break
                }
            }
            if let audioId = outgoingAudioId, let loc = findClip(id: audioId) {
                record.previousOutgoingAudioClipId = audioId
                record.previousOutgoingAudioFadeOut = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].fadeOutFrames
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex].fadeOutFrames = plan.audioFade
            }
            let incomingAudioTarget: String? = type == .dipToBlack ? incomingAudioId : record.overlayClipIds.last
            if let audioId = incomingAudioTarget, let loc = findClip(id: audioId) {
                record.previousIncomingAudioClipId = audioId
                record.previousIncomingAudioFadeIn = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].fadeInFrames
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex].fadeInFrames = plan.audioFade
            }
            timeline.transitions.append(record)
        }
        onProjectCheckpointRequired?()
        return record
    }

    @discardableResult
    func removeTransition(id: String) throws -> TimelineTransition {
        guard let record = timeline.transitions.first(where: { $0.id == id }) else {
            throw TransitionValidationError.unknownTransition(id)
        }
        withTimelineSwap(actionName: "Remove Transition") {
            for overlayId in record.overlayClipIds {
                for i in timeline.tracks.indices {
                    timeline.tracks[i].clips.removeAll { $0.id == overlayId }
                }
            }
            if record.type == .dipToBlack {
                for clipId in [record.outgoingClipId, record.incomingClipId] {
                    guard let loc = findClip(id: clipId) else { continue }
                    var clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                    // Only clear what this transition wrote; a user edit afterwards is theirs.
                    if clip.opacityTrack?.keyframes.count == 2 {
                        clip.opacityTrack = nil
                        timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
                    }
                }
            }
            if let audioId = record.previousOutgoingAudioClipId,
               let loc = findClip(id: audioId) {
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex].fadeOutFrames =
                    record.previousOutgoingAudioFadeOut
            }
            if let audioId = record.previousIncomingAudioClipId,
               let loc = findClip(id: audioId) {
                timeline.tracks[loc.trackIndex].clips[loc.clipIndex].fadeInFrames =
                    record.previousIncomingAudioFadeIn
            }
            timeline.transitions.removeAll { $0.id == id }
            pruneEmptyTracks()
        }
        onProjectCheckpointRequired?()
        return record
    }

    private func linkedAudioClipId(for clip: Clip) -> String? {
        guard let group = clip.linkGroupId else { return nil }
        return timeline.tracks.flatMap(\.clips).first {
            $0.id != clip.id && $0.linkGroupId == group && $0.mediaType == .audio
        }?.id
    }

    private func setOpacityTrack(clipId: String, rows: [(Int, Double)]) {
        guard let loc = findClip(id: clipId) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].opacityTrack = KeyframeTrack(keyframes:
            rows.map { Keyframe(frame: $0.0, value: $0.1) }
        )
    }

    private func setPositionTrack(clipId: String, rows: [(Int, (Double, Double))]) {
        guard let loc = findClip(id: clipId) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].positionTrack = KeyframeTrack(keyframes:
            rows.map { Keyframe(frame: $0.0, value: AnimPair(a: $0.1.0, b: $0.1.1)) }
        )
    }

    private func slideEntryPoint(direction: TransitionDirection) -> (Double, Double) {
        switch direction {
        case .left: (1, 0)
        case .right: (-1, 0)
        case .up: (0, 1)
        case .down: (0, -1)
        }
    }

    private func slideExitPoint(direction: TransitionDirection) -> (Double, Double) {
        switch direction {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
    }
}
