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
    case audioFade(AudioFadeDrag)
    case marquee(MarqueeDrag)

    struct AudioFadeDrag {
        let clipId: String
        let trackIndex: Int
        let edge: FadeEdge
        let originalFadeFrames: Int
        var deltaFrames: Int = 0

        func resolvedFadeFrames(for clip: Clip) -> Int {
            clip.clampedFade(originalFadeFrames + deltaFrames, edge: edge)
        }
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
