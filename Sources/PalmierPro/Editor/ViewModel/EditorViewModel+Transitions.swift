import Foundation

enum TransitionError: LocalizedError {
    case clipNotFound(String)
    case unsupportedMedia(String)
    case notAdjacent
    case invalidDuration(Int, max: Int)
    case unknownType(String)

    var errorDescription: String? {
        switch self {
        case .clipNotFound(let id): return "Clip not found: \(id)"
        case .unsupportedMedia(let id):
            return "Clip \(id) cannot take a transition (video, image, audio, or lottie only)."
        case .notAdjacent:
            return "Clips must be adjacent on the same track (or already share this transition)."
        case .invalidDuration(let d, let max):
            return "durationFrames \(d) is out of range (1…\(max))."
        case .unknownType(let t): return "Unknown transition '\(t)'."
        }
    }
}

extension EditorViewModel {

    /// Default transition length: half a second in project frames.
    func defaultTransitionDurationFrames() -> Int {
        max(2, timeline.fps / 2)
    }

    /// Apply or replace a transition between two clips. Creates an overlap of `durationFrames`
    /// by shifting the incoming clip (and later clips on that track) earlier. Linked audio
    /// partners receive the same shift and a matching volume crossfade.
    func applyTransition(
        outgoingId: String,
        incomingId: String,
        type: String,
        durationFrames: Int?
    ) throws {
        guard TransitionRegistry.contains(type) else { throw TransitionError.unknownType(type) }
        guard let outLoc = findClip(id: outgoingId) else { throw TransitionError.clipNotFound(outgoingId) }
        guard let inLoc = findClip(id: incomingId) else { throw TransitionError.clipNotFound(incomingId) }
        guard outLoc.trackIndex == inLoc.trackIndex else { throw TransitionError.notAdjacent }

        let trackIndex = outLoc.trackIndex
        let outgoing = timeline.tracks[trackIndex].clips[outLoc.clipIndex]
        let incoming = timeline.tracks[trackIndex].clips[inLoc.clipIndex]
        guard outgoing.supportsTransition else { throw TransitionError.unsupportedMedia(outgoingId) }
        guard incoming.supportsTransition else { throw TransitionError.unsupportedMedia(incomingId) }

        let duration = durationFrames ?? defaultTransitionDurationFrames()
        let maxDuration = min(outgoing.durationFrames, incoming.durationFrames) - 1
        guard duration >= 1, maxDuration >= 1, duration <= maxDuration else {
            throw TransitionError.invalidDuration(duration, max: max(1, maxDuration))
        }

        let currentOverlap = Clip.overlapFrames(outgoing: outgoing, incoming: incoming)
        let abutting = incoming.startFrame == outgoing.endFrame
        let validExisting = Clip.hasValidTransition(outgoing: outgoing, incoming: incoming)
        guard abutting || validExisting || (currentOverlap > 0 && incoming.transition != nil) else {
            throw TransitionError.notAdjacent
        }

        let oldIncomingStart = incoming.startFrame
        let targetStart = outgoing.endFrame - duration
        let delta = targetStart - oldIncomingStart
        let partnersIn = linkedPartnerIds(of: incomingId)
        let partnersOut = linkedPartnerIds(of: outgoingId)

        withTimelineSwap(actionName: "Apply Transition") {
            if delta != 0 {
                shiftClipAndPartners(id: incomingId, by: delta)
                shiftLaterClips(
                    on: trackIndex,
                    fromFrame: oldIncomingStart + 1,
                    by: delta,
                    excluding: Set([incomingId] + partnersIn)
                )
            }

            setTransition(on: incomingId, type: type, durationFrames: duration)

            if outgoing.mediaType != .audio {
                setFadeFrames(on: outgoingId, edge: .right, frames: 0)
            }
            if incoming.mediaType != .audio {
                setFadeFrames(on: incomingId, edge: .left, frames: 0)
            } else {
                setFadeFrames(on: outgoingId, edge: .right, frames: duration)
                setFadeFrames(on: incomingId, edge: .left, frames: duration)
            }

            for pid in partnersOut where clipFor(id: pid)?.mediaType == .audio {
                setFadeFrames(on: pid, edge: .right, frames: duration)
            }
            for pid in partnersIn where clipFor(id: pid)?.mediaType == .audio {
                setTransition(on: pid, type: "dissolve", durationFrames: duration)
                setFadeFrames(on: pid, edge: .left, frames: duration)
            }

            sanitizeTransitions(on: trackIndex)
            for pid in partnersIn {
                if let loc = findClip(id: pid) { sanitizeTransitions(on: loc.trackIndex) }
            }
        }
    }

    /// Remove the incoming transition and restore an abutting cut.
    func removeTransition(incomingId: String) throws {
        guard let loc = findClip(id: incomingId) else { throw TransitionError.clipNotFound(incomingId) }
        let incoming = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard let transition = incoming.transition else { return }

        let duration = transition.durationFrames
        let oldIncomingStart = incoming.startFrame
        let partnersIn = linkedPartnerIds(of: incomingId)
        let trackIndex = loc.trackIndex
        let outgoingId = previousOverlappingClip(on: trackIndex, incoming: incoming)?.id

        withTimelineSwap(actionName: "Remove Transition") {
            clearTransition(on: incomingId)
            setFadeFrames(on: incomingId, edge: .left, frames: 0)
            for pid in partnersIn {
                clearTransition(on: pid)
                setFadeFrames(on: pid, edge: .left, frames: 0)
            }
            if let outgoingId {
                setFadeFrames(on: outgoingId, edge: .right, frames: 0)
                for pid in linkedPartnerIds(of: outgoingId) {
                    setFadeFrames(on: pid, edge: .right, frames: 0)
                }
            }

            shiftClipAndPartners(id: incomingId, by: duration)
            shiftLaterClips(
                on: trackIndex,
                fromFrame: oldIncomingStart + 1,
                by: duration,
                excluding: Set([incomingId] + partnersIn)
            )
            sanitizeTransitions(on: trackIndex)
        }
    }

    /// Drop transitions that no longer match overlap geometry on a track.
    func sanitizeTransitions(on trackIndex: Int) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let sorted = timeline.tracks[trackIndex].clips.sorted { $0.startFrame < $1.startFrame }
        var keep = Set<String>()
        for i in 1..<sorted.count {
            if Clip.hasValidTransition(outgoing: sorted[i - 1], incoming: sorted[i]) {
                keep.insert(sorted[i].id)
            }
        }
        for ci in timeline.tracks[trackIndex].clips.indices {
            if timeline.tracks[trackIndex].clips[ci].transition != nil,
               !keep.contains(timeline.tracks[trackIndex].clips[ci].id) {
                timeline.tracks[trackIndex].clips[ci].transition = nil
            }
        }
    }

    func sanitizeAllTransitions() {
        for i in timeline.tracks.indices { sanitizeTransitions(on: i) }
    }

    // MARK: - Internals

    private func setTransition(on clipId: String, type: String, durationFrames: Int) {
        guard let loc = findClip(id: clipId) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].transition =
            ClipTransition(type: type, durationFrames: durationFrames)
    }

    private func clearTransition(on clipId: String) {
        guard let loc = findClip(id: clipId) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].transition = nil
    }

    private func setFadeFrames(on clipId: String, edge: FadeEdge, frames: Int) {
        guard let loc = findClip(id: clipId) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].setFade(edge, frames: frames)
    }

    private func shiftClipAndPartners(id: String, by delta: Int) {
        guard delta != 0 else { return }
        shiftClipStart(id: id, by: delta)
        for pid in linkedPartnerIds(of: id) {
            shiftClipStart(id: pid, by: delta)
        }
    }

    private func shiftClipStart(id: String, by delta: Int) {
        guard delta != 0, let loc = findClip(id: id) else { return }
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame =
            max(0, timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame + delta)
    }

    private func shiftLaterClips(on trackIndex: Int, fromFrame: Int, by delta: Int, excluding: Set<String>) {
        guard delta != 0, timeline.tracks.indices.contains(trackIndex) else { return }
        var shifted: [String] = []
        for ci in timeline.tracks[trackIndex].clips.indices {
            let clip = timeline.tracks[trackIndex].clips[ci]
            guard !excluding.contains(clip.id), clip.startFrame >= fromFrame else { continue }
            timeline.tracks[trackIndex].clips[ci].startFrame = max(0, clip.startFrame + delta)
            shifted.append(clip.id)
        }
        for id in shifted {
            for pid in linkedPartnerIds(of: id) where !excluding.contains(pid) {
                shiftClipStart(id: pid, by: delta)
            }
        }
        sortClips(trackIndex: trackIndex)
    }

    private func previousOverlappingClip(on trackIndex: Int, incoming: Clip) -> Clip? {
        timeline.tracks[trackIndex].clips
            .filter { $0.id != incoming.id && $0.startFrame < incoming.startFrame && $0.endFrame > incoming.startFrame }
            .sorted { $0.startFrame < $1.startFrame }
            .last
    }
}
