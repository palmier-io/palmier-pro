import Foundation

enum AudioOffsetError: Error, Equatable, CustomStringConvertible {
    case unknownClip(String)
    case notLinked(String)
    case alreadyOffset(String, offsetFrames: Int)
    case sameClip
    case notAudioOrVideo(String)
    case offsetOutOfRange(frames: Int, headroomBefore: Int, headroomAfter: Int)
    case noOverhang(offsetFrames: Int)
    case noSourceHeadroom(clipId: String, neededFrames: Int, availableFrames: Int)

    var description: String {
        switch self {
        case .unknownClip(let id): "Clip not found: \(id)."
        case .notLinked(let id):
            "Clip \(id) has no linked audio partner. Only a linked video/audio pair can be offset."
        case .alreadyOffset(let id, let frames):
            "Clip \(id) is already offset by \(frames) frames. Clear it with clear_audio_offset first."
        case .sameClip: "Provide two different clips: the video and the audio to offset."
        case .notAudioOrVideo(let id):
            "Clip \(id) is neither a video nor an audio clip."
        case .offsetOutOfRange(let frames, let before, let after):
            "Offset \(frames) frames exceeds the available room "
                + "(\(before) frames before the pair, \(after) after)."
        case .noOverhang(let frames):
            "An offset of \(frames) frames leaves no audio on the other side of the cut. "
                + "It must be shorter than the clip."
        case .noSourceHeadroom(let id, let needed, let available):
            "Clip \(id) needs \(needed) frames of source to shift by that much but only has "
                + "\(available). Trim elsewhere or offset less."
        }
    }
}

extension EditorViewModel {
    struct AudioOffsetReceipt: Sendable, Equatable {
        var videoClipId: String
        var audioClipId: String
        /// Timeline frame the cut happens on.
        var cutFrame: Int
        /// Positive = audio starts before the video cut (J-cut). Negative = audio runs past it (L-cut).
        var offsetFrames: Int
        var kind: String
        var audioStartFrame: Int
        var audioEndFrame: Int
    }

    /// Offsets a linked video/audio pair across the cut between them, as one undo step.
    ///
    /// A J-cut starts the next shot's audio before its picture; an L-cut holds the outgoing
    /// audio over the incoming picture. Both are the same arithmetic: one member of a link group
    /// moves, the link stays intact, and the offset is the delta the domain already reads back
    /// through `linkGroupOffsets`.
    @discardableResult
    func offsetLinkedAudio(
        videoId: String,
        audioId: String,
        offsetFrames: Int
    ) throws -> AudioOffsetReceipt {
        guard videoId != audioId else { throw AudioOffsetError.sameClip }
        guard let videoLocation = findClip(id: videoId) else {
            throw AudioOffsetError.unknownClip(videoId)
        }
        guard let audioLocation = findClip(id: audioId) else {
            throw AudioOffsetError.unknownClip(audioId)
        }
        let video = timeline.tracks[videoLocation.trackIndex].clips[videoLocation.clipIndex]
        let audio = timeline.tracks[audioLocation.trackIndex].clips[audioLocation.clipIndex]
        guard video.mediaType.isVisual, audio.mediaType == .audio else {
            throw AudioOffsetError.notAudioOrVideo(videoId)
        }
        guard let groupId = video.linkGroupId, groupId == audio.linkGroupId else {
            throw AudioOffsetError.notLinked(audioId)
        }
        // Zero offset and any pre-existing offset are ambiguous states; refuse rather than guess.
        let existing = audio.startFrame - video.startFrame
        guard existing == 0 else {
            throw AudioOffsetError.alreadyOffset(audioId, offsetFrames: existing)
        }
        guard offsetFrames != 0 else { throw AudioOffsetError.noOverhang(offsetFrames: 0) }
        // The shifted audio must still overlap the video, or the link is meaningless.
        guard abs(offsetFrames) < min(video.durationFrames, audio.durationFrames) else {
            throw AudioOffsetError.noOverhang(offsetFrames: offsetFrames)
        }
        // The two cuts are asymmetric, which is the whole point of them.
        //   J-cut (positive): the next shot's sound arrives before its picture, so the audio
        //     head moves earlier and reads source from before the video's own start.
        //   L-cut (negative): the outgoing sound runs on past its picture, so the audio tail
        //     extends and gives back the tail trim it was holding.
        let tailRoom = max(0, mediaLengthFrames(for: audio).map { $0 - audio.trimStartFrame - audio.sourceFramesConsumed } ?? Int.max)
        if offsetFrames > 0 {
            guard audio.startFrame >= offsetFrames else {
                throw AudioOffsetError.offsetOutOfRange(
                    frames: offsetFrames,
                    headroomBefore: audio.startFrame,
                    headroomAfter: 0
                )
            }
            let needed = audio.trimStartFrame + offsetFrames
            let available = mediaLengthFrames(for: audio)
            if let available, needed > available {
                throw AudioOffsetError.noSourceHeadroom(
                    clipId: audioId, neededFrames: needed, availableFrames: available
                )
            }
        } else {
            let tail = -offsetFrames
            guard tail <= tailRoom else {
                throw AudioOffsetError.offsetOutOfRange(
                    frames: offsetFrames,
                    headroomBefore: 0,
                    headroomAfter: tailRoom == Int.max ? tail : tailRoom
                )
            }
        }

        let cut = video.startFrame
        withTimelineSwap(actionName: offsetFrames > 0 ? "J-Cut" : "L-Cut") {
            let index = audioLocation.trackIndex
            let current = timeline.tracks[index].clips[audioLocation.clipIndex]
            var moved = current
            if offsetFrames > 0 {
                moved.startFrame = current.startFrame - offsetFrames
                moved.trimStartFrame = current.trimStartFrame + offsetFrames
            } else {
                let tail = -offsetFrames
                moved.durationFrames = current.durationFrames + tail
                moved.trimEndFrame = max(0, current.trimEndFrame - tail)
            }
            moved.clampKeyframesToDuration()
            moved.clampFadesToDuration()
            timeline.tracks[index].clips[audioLocation.clipIndex] = moved
            _ = groupId
        }
        onProjectCheckpointRequired?()
        let placed = timeline.tracks[audioLocation.trackIndex].clips[audioLocation.clipIndex]
        return AudioOffsetReceipt(
            videoClipId: videoId,
            audioClipId: audioId,
            cutFrame: cut,
            offsetFrames: offsetFrames,
            kind: offsetFrames > 0 ? "jCut" : "lCut",
            audioStartFrame: placed.startFrame,
            audioEndFrame: placed.endFrame
        )
    }

    /// Returns a link group to picture-locked, as one undo step.
    @discardableResult
    func clearAudioOffset(videoId: String) throws -> AudioOffsetReceipt {
        guard let videoLocation = findClip(id: videoId) else {
            throw AudioOffsetError.unknownClip(videoId)
        }
        let video = timeline.tracks[videoLocation.trackIndex].clips[videoLocation.clipIndex]
        guard let groupId = video.linkGroupId else {
            throw AudioOffsetError.notLinked(videoId)
        }
        let partners = linkedPartnerIds(of: videoId)
        let audioId = partners.first { id in
            findClip(id: id).map { find in
                timeline.tracks[find.trackIndex].clips[find.clipIndex].mediaType == .audio
            } ?? false
        }
        guard let audioId else { throw AudioOffsetError.notLinked(videoId) }
        guard let audioLocation = findClip(id: audioId) else {
            throw AudioOffsetError.unknownClip(audioId)
        }
        let audio = timeline.tracks[audioLocation.trackIndex].clips[audioLocation.clipIndex]
        let offset = audio.startFrame - video.startFrame
        guard offset != 0 else {
            throw AudioOffsetError.alreadyOffset(audioId, offsetFrames: 0)
        }
        withTimelineSwap(actionName: "Clear Audio Offset") {
            let index = audioLocation.trackIndex
            var moved = timeline.tracks[index].clips[audioLocation.clipIndex]
            if offset < 0 {
                // It was an L-cut: pull the tail back in and take the trim again.
                moved.durationFrames = max(1, moved.durationFrames + offset)
                moved.trimEndFrame = moved.trimEndFrame - offset
            } else {
                // It was a J-cut: push the head back and return the source it consumed.
                moved.trimStartFrame = max(0, moved.trimStartFrame - offset)
                moved.startFrame = moved.startFrame + offset
            }
            moved.clampKeyframesToDuration()
            moved.clampFadesToDuration()
            timeline.tracks[index].clips[audioLocation.clipIndex] = moved
        }
        onProjectCheckpointRequired?()
        _ = groupId
        let placed = timeline.tracks[audioLocation.trackIndex].clips[audioLocation.clipIndex]
        return AudioOffsetReceipt(
            videoClipId: videoId, audioClipId: audioId, cutFrame: video.startFrame,
            offsetFrames: 0, kind: "none",
            audioStartFrame: placed.startFrame, audioEndFrame: placed.endFrame
        )
    }

    private func mediaLengthFrames(for clip: Clip) -> Int? {
        guard let asset = mediaAssetsById[clip.mediaRef], timeline.fps > 0 else { return nil }
        let frames = Int((asset.duration * Double(timeline.fps)).rounded())
        return frames > 0 ? frames : nil
    }
}
