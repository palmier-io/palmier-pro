import AppKit

/// Value type representing the current drag-in-progress state.
/// Stored on TimelineInputController, never on EditorViewModel.
/// Uses delta-only model: no model mutation during drag.
enum DragState {
    case idle
    case scrubPlayhead
    case moveClip(MoveClipDrag)
    case trimLeft(TrimDrag)
    case trimRight(TrimDrag)
    case marquee(MarqueeDrag)
    case resizeTrack(trackIndex: Int, originalHeight: CGFloat)

    struct MoveClipDrag {
        let clipId: String
        let originalTrack: Int
        let originalFrame: Int
        let grabOffsetFrames: Int
        var deltaFrames: Int = 0
        var dropTarget: TrackDropTarget
        var companions: [CompanionClip] = []
    }

    struct CompanionClip {
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
        var deltaFrames: Int = 0
    }

    struct MarqueeDrag {
        let origin: NSPoint
        var current: NSRect = .zero
    }
}
