/// Pure functions for overwrite editing: computing how to clear a region
/// of the timeline by removing, trimming, or splitting existing clips.
/// Stdlib-only — the new clip id generated on a split is supplied by the
/// caller via `idProvider`, keeping the engine deterministic and portable.
public enum OverwriteEngine {

    public enum Action: Equatable, Sendable {
        case remove(clipId: String)

        case trimEnd(clipId: String, newDuration: Int)

        case trimStart(clipId: String, newStartFrame: Int, newTrimStart: Int, newDuration: Int)

        case split(
            clipId: String,
            leftDuration: Int,
            rightId: String,
            rightStartFrame: Int,
            rightTrimStart: Int,
            rightDuration: Int
        )
    }

    /// Given a region [regionStart, regionEnd) on a track, returns the actions
    /// needed to clear that region so a new clip can be placed there.
    /// `idProvider` supplies the id for any new clip created by a split.
    public static func computeOverwrite<C: RippleClip>(
        clips: [C],
        regionStart: Int,
        regionEnd: Int,
        idProvider: () -> String
    ) -> [Action] {
        guard regionEnd > regionStart else { return [] }
        var actions: [Action] = []

        for clip in clips {
            let cs = clip.startFrame
            let ce = clip.endFrame

            if ce <= regionStart || cs >= regionEnd {
                continue
            }

            if cs >= regionStart && ce <= regionEnd {
                actions.append(.remove(clipId: clip.id))
            } else if cs < regionStart && ce > regionEnd {
                let leftDuration = regionStart - cs
                let rightStartFrame = regionEnd
                let rightTrimStart = clip.trimStartFrame + Int((Double(regionEnd - cs) * clip.speed).rounded())
                let rightDuration = ce - regionEnd
                actions.append(.split(
                    clipId: clip.id,
                    leftDuration: leftDuration,
                    rightId: idProvider(),
                    rightStartFrame: rightStartFrame,
                    rightTrimStart: rightTrimStart,
                    rightDuration: rightDuration
                ))
            } else if cs < regionStart {
                // Overlaps left side — trim right edge
                let newDuration = regionStart - cs
                actions.append(.trimEnd(clipId: clip.id, newDuration: newDuration))
            } else {
                // Overlaps right side — trim left edge
                let trimAmount = regionEnd - cs
                let newStartFrame = regionEnd
                let newTrimStart = clip.trimStartFrame + Int((Double(trimAmount) * clip.speed).rounded())
                let newDuration = ce - regionEnd
                actions.append(.trimStart(
                    clipId: clip.id,
                    newStartFrame: newStartFrame,
                    newTrimStart: newTrimStart,
                    newDuration: newDuration
                ))
            }
        }

        return actions
    }
}
