import Foundation

struct GapTransitionContext: Equatable, Sendable {
    let timelineId: String
    let trackId: String
    let trackIndex: Int
    let range: FrameRange
    let previousClipId: String
    let nextClipId: String
}

enum GapTransitionPlanner {
    static let minimumSeconds = 4
    static let maximumSeconds = 15
    static let prompt = "Create a seemless transition between the first and last frame"

    static func context(for gap: GapSelection, in timeline: Timeline) -> GapTransitionContext? {
        guard timeline.fps > 0,
              timeline.fps <= Int.max / maximumSeconds,
              timeline.tracks.indices.contains(gap.trackIndex),
              gap.range.start > 0,
              gap.range.length >= minimumSeconds * timeline.fps,
              gap.range.length <= maximumSeconds * timeline.fps else { return nil }

        let track = timeline.tracks[gap.trackIndex]
        guard track.type == .video,
              !track.clips.contains(where: {
                  $0.startFrame < gap.range.end && $0.endFrame > gap.range.start
              }) else { return nil }

        let previous = track.clips.filter {
            $0.endFrame == gap.range.start && $0.mediaType.isVisual
        }
        let next = track.clips.filter {
            $0.startFrame == gap.range.end && $0.mediaType.isVisual
        }
        guard previous.count == 1, next.count == 1 else { return nil }

        return GapTransitionContext(
            timelineId: timeline.id,
            trackId: track.id,
            trackIndex: gap.trackIndex,
            range: gap.range,
            previousClipId: previous[0].id,
            nextClipId: next[0].id
        )
    }

    static func generationDuration(
        gapFrameCount: Int,
        fps: Int,
        supportedDurations: [Int]
    ) -> Int? {
        guard fps > 0,
              fps <= Int.max / maximumSeconds,
              gapFrameCount >= minimumSeconds * fps,
              gapFrameCount <= maximumSeconds * fps else { return nil }

        return supportedDurations
            .filter { duration in
                duration >= minimumSeconds
                    && duration <= maximumSeconds
                    && duration * fps >= gapFrameCount
            }
            .min()
    }

    static func playbackRate(
        generationDurationSeconds: Int,
        targetFrameCount: Int,
        fps: Int
    ) -> Double? {
        guard generationDurationSeconds > 0,
              generationDurationSeconds <= maximumSeconds,
              targetFrameCount > 0,
              fps > 0,
              fps <= Int.max / generationDurationSeconds else { return nil }
        return Double(generationDurationSeconds * fps) / Double(targetFrameCount)
    }
}
