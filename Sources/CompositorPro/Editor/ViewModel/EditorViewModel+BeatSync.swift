import Foundation

enum BeatSyncError: Error, Equatable, CustomStringConvertible {
    case unknownClip(String)
    case notAVAsset(String)
    case noBeats(mediaRef: String, kind: String)
    case indexOutOfRange(Int, available: Int)
    case beatBeforeClip(Int)
    case beatAfterClip(Int, lastFrame: Int)
    case nothingToCut

    var description: String {
        switch self {
        case .unknownClip(let id): "Clip not found: \(id)."
        case .notAVAsset(let ref): "No beat analysis for \(ref). Run detect_beats on it first."
        case .noBeats(let ref, let kind):
            "No \(kind) found in \(ref). Pick a track with a clearer pulse."
        case .indexOutOfRange(let index, let available):
            "Beat index \(index) is out of range; this analysis has \(available) entries."
        case .beatBeforeClip(let frame):
            "Beat \(frame) lands before the clip starts."
        case .beatAfterClip(let frame, let last):
            "Beat \(frame) lands after the clip ends (last frame \(last))."
        case .nothingToCut: "No beat landed inside the clip, so there is nothing to cut on."
        }
    }
}

extension EditorViewModel {
    struct BeatCut: Sendable, Equatable {
        var index: Int
        var beatSeconds: Double
        /// Unsnapped frame the beat maps to.
        var exactFrame: Int
        /// Where the cut was actually made, after snapping.
        var frame: Int
        /// Frames the snap moved the cut, for honest reporting.
        var snappedBy: Int
    }

    struct BeatSyncReceipt: Sendable, Equatable {
        var clipId: String
        var usedDownbeats: Bool
        /// True when the grid came from the analysis detect_beats already ran.
        var reusedCachedBeats: Bool
        var cuts: [BeatCut]
    }

    /// Cuts a clip at the music's beats, in one undo step.
    ///
    /// The seconds→frames conversion, the trim arithmetic and the split all happen here, so the
    /// Agent does not have to reproduce the mapping and land cuts between beats. Every cut
    /// reports the frame it actually used, so a follow-up effect can sit exactly on it.
    func syncClipToBeats(
        clipId: String,
        musicRef: String,
        requestedIndices: [Int]?,
        useDownbeats: Bool,
        snapFrames: Int
    ) async throws -> BeatSyncReceipt {
        var usedCache = false
        defer { _ = usedCache }
        guard let location = findClip(id: clipId) else { throw BeatSyncError.unknownClip(clipId) }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard mediaAssetsById[musicRef] != nil else {
            throw BeatSyncError.notAVAsset(musicRef)
        }
        // Prefer the analysis detect_beats already produced. Only pay for detection when the
        // caller skipped that step, and say which happened.
        let beats: BeatGrid
        if let cached = mediaVisualCache.beats.analysis(for: musicRef) {
            beats = BeatGrid(beats: cached.beats, downbeats: cached.downbeats)
            usedCache = true
        } else {
            guard let asset = mediaAssetsById[musicRef] else {
                throw BeatSyncError.notAVAsset(musicRef)
            }
            let analysis = try await mediaVisualCache.beats.detect(for: asset).value
            beats = BeatGrid(beats: analysis.beats, downbeats: analysis.downbeats)
        }
        let grid = useDownbeats ? beats.downbeats : beats.beats
        let kind = useDownbeats ? "downbeats" : "beats"
        guard !grid.isEmpty else { throw BeatSyncError.noBeats(mediaRef: musicRef, kind: kind) }

        // Source seconds of the music → the timeline frames they land on inside this clip.
        let map = clip.timeMap
        let fps = Double(timeline.fps)
        let trimSeconds = Double(clip.trimStartFrame) / fps
        var candidates: [(index: Int, seconds: Double, exactFrame: Int)] = []
        if let requestedIndices {
            for index in requestedIndices {
                guard index >= 0, index < grid.count else {
                    throw BeatSyncError.indexOutOfRange(index, available: grid.count)
                }
                let seconds = grid[index]
                let sourceFrame = (seconds - trimSeconds) * fps
                let exact = clip.startFrame + map.timelineOffset(forSourceOffset: sourceFrame)
                guard exact > clip.startFrame, exact < clip.endFrame else { continue }
                candidates.append((index, seconds, exact))
            }
        } else {
            for (index, seconds) in grid.enumerated() {
                let sourceFrame = (seconds - trimSeconds) * fps
                let exact = clip.startFrame + map.timelineOffset(forSourceOffset: sourceFrame)
                guard exact > clip.startFrame, exact < clip.endFrame else { continue }
                candidates.append((index, seconds, exact))
            }
        }
        guard !candidates.isEmpty else { throw BeatSyncError.nothingToCut }
        let snap = max(0, snapFrames)
        var cuts: [BeatCut] = []
        for candidate in candidates {
            let lower = max(clip.startFrame + 1, candidate.exactFrame - snap)
            let upper = min(clip.endFrame - 1, candidate.exactFrame + snap)
            let frame = min(max(candidate.exactFrame, lower), upper)
            cuts.append(BeatCut(
                index: candidate.index, beatSeconds: candidate.seconds,
                exactFrame: candidate.exactFrame, frame: frame,
                snappedBy: frame - candidate.exactFrame
            ))
        }
        guard cuts.count >= 1 else { throw BeatSyncError.nothingToCut }

        withTimelineSwap(actionName: "Cut on Beats") {
            for cut in cuts.reversed() where cut.frame > clip.startFrame && cut.frame < clip.endFrame {
                splitSingleClip(clipId: clipId, atFrame: cut.frame)
            }
        }
        onProjectCheckpointRequired?()
        return BeatSyncReceipt(
            clipId: clipId, usedDownbeats: useDownbeats, reusedCachedBeats: usedCache,
            cuts: cuts.filter { $0.frame > clip.startFrame && $0.frame < clip.endFrame }
        )
    }

    private struct BeatGrid {
        var beats: [Double]
        var downbeats: [Double]
    }

}
