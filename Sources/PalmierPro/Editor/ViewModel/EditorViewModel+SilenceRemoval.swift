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

    /// The single selected audio/video clip eligible for silence removal, or nil.
    var silenceRemovalCandidate: Clip? {
        guard selectedClipIds.count == 1,
              let clipId = selectedClipIds.first,
              let loc = findClip(id: clipId) else { return nil }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType == .video || clip.mediaType == .audio else { return nil }
        return clip
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
