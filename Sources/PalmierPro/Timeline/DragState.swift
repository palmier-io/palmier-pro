import AppKit

enum DragState {
    case idle
    case scrubPlayhead
    case moveClip(MoveClipDrag)
    case trimLeft(TrimDrag)
    case trimRight(TrimDrag)
    case audioVolumeKf(AudioVolumeKfDrag)
    case marquee(MarqueeDrag)

    struct AudioVolumeKfDrag {
        let clipId: String
        let trackIndex: Int
        /// kf's absolute frame at drag-start; used by mouseUp to detect no-op drags.
        let originalFrame: Int
        /// kf's dB at drag-start; mouseUp comparison companion to `originalFrame`.
        let originalDb: Double
        /// Cursor frame at drag-start; preserves the pointer's offset to the kf as it moves.
        let grabFrame: Int
        /// Clip-relative corner offset (0 / durationFrames). `nil` for diamonds, which drag in 2D.
        let fadeHandleCorner: Int?
        /// kf's current absolute frame; tells the next tick where to find the kf to move.
        var currentFrame: Int
        /// kf's current dB; tells the next tick the kf's current value.
        var currentDb: Double

        var isFadeHandle: Bool { fadeHandleCorner != nil }
    }

    struct MoveClipDrag {
        /// Clip the user grabbed. Vertical drag only relocates this clip.
        let lead: Participant
        /// Other selected/linked clips that follow horizontally but stay on their own tracks.
        var companions: [Participant] = []
        let grabOffsetFrames: Int
        var deltaFrames: Int = 0
        var dropTarget: TrackDropTarget

        var all: [Participant] { [lead] + companions }

        func isLead(_ p: Participant) -> Bool { p.clipId == lead.clipId }
    }

    struct Participant {
        let clipId: String
        let originalTrack: Int
        let originalFrame: Int
    }

    struct TrimDrag {
        let clipId: String
        let trackIndex: Int
        let originalTrimStart: Int
        let originalTrimEnd: Int
        let originalStartFrame: Int
        let originalDuration: Int
        /// Image/Text clips can be trimmed/extended freely without hitting a source-material cap.
        let hasNoSourceMedia: Bool
        /// When true, trim applies to link-group partners too.
        let propagateToLinked: Bool
        var deltaFrames: Int = 0
    }

    struct MarqueeDrag {
        let origin: NSPoint
        var current: NSRect = .zero
        var baseSelection: Set<String> = []
    }
}
