import Foundation

enum SilenceRemovalError: LocalizedError {
    case noClipSelected
    case noAudioContent
    case assetNotFound

    var errorDescription: String? {
        switch self {
        case .noClipSelected: "Select a single audio or video clip first."
        case .noAudioContent: "Clip has no audio content."
        case .assetNotFound: "Source media not found."
        }
    }
}

extension EditorViewModel {

    /// The audio/video clip to use as the silence-detection source, or nil.
    ///
    /// Accepts a single selected A/V clip, or a set of clips that all share one link group
    /// (e.g. a linked camera-video + audio pair). In the linked case the audio clip is
    /// preferred as the detection source; `removeSilences` then runs the ripple on that
    /// track and the engine cuts the linked video partner automatically.
    var silenceRemovalCandidate: Clip? {
        guard !selectedClipIds.isEmpty else { return nil }

        let clips: [Clip] = selectedClipIds.compactMap { id in
            guard let loc = findClip(id: id) else { return nil }
            return timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        }
        guard clips.count == selectedClipIds.count else { return nil }

        // All selected clips must be audio or video — text/caption clips disqualify.
        guard clips.allSatisfy({ $0.mediaType == .video || $0.mediaType == .audio }) else { return nil }

        if clips.count == 1 { return clips[0] }

        // Multiple clips: allow only when they all share exactly one link group.
        let groupIds = Set(clips.compactMap(\.linkGroupId))
        guard groupIds.count == 1 else { return nil }

        // Prefer the dedicated audio clip as the detection source so the waveform
        // is read from the correct asset. Fall back to video (which may carry audio).
        return clips.first { $0.mediaType == .audio } ?? clips.first { $0.mediaType == .video }
    }

    /// Extract the clip's audio envelope and detect silent source-second ranges.
    func detectSilences(for clip: Clip, config: SilenceConfig) async throws -> [(start: Double, end: Double)] {
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }),
              asset.type == .video || asset.type == .audio else {
            throw SilenceRemovalError.assetNotFound
        }
        guard asset.hasAudio || asset.type == .audio else { throw SilenceRemovalError.noAudioContent }
        let envelope = try await AudioEnvelopeExtractor.extract(from: asset.url)
        return SilenceDetector.detect(envelope: envelope, config: config)
    }

    /// Detect silences on the currently selected clip.
    func detectSilences(config: SilenceConfig) async throws -> [(start: Double, end: Double)] {
        guard let clip = silenceRemovalCandidate else { throw SilenceRemovalError.noClipSelected }
        return try await detectSilences(for: clip, config: config)
    }

    /// Ripple-delete the given source-second silence ranges from `clip`. Returns frames removed.
    @discardableResult
    func removeSilences(clip: Clip, silences: [(start: Double, end: Double)]) -> Int {
        guard let loc = findClip(id: clip.id) else { return 0 }
        let ranges = SilenceDetector.timelineRanges(silences: silences, clip: clip, fps: timeline.fps)
        guard !ranges.isEmpty else { return 0 }
        let outcome = rippleDeleteRangesOnTrack(trackIndex: loc.trackIndex, ranges: ranges)
        guard case .ok(let report) = outcome else { return 0 }
        return report.removedFrames
    }
}
