import Foundation

enum TransitionType: String, Codable, Sendable, CaseIterable {
    case dissolve
    case dipToBlack
    case slide
    case push
}

enum TransitionDirection: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case up
    case down
}

/// A transition between two adjacent same-track clips.
///
/// Timeline clips stay sequential and non-overlapping; only the render overlaps. Dissolve,
/// slide and push build that overlap with an upper-track copy of the incoming clip, while
/// dip-to-black needs no overlap and is expressed as opacity keyframes on the two clips.
struct TimelineTransition: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var outgoingClipId: String
    var incomingClipId: String
    var trackId: String
    var overlayClipIds: [String] = []
    var type: TransitionType
    var direction: TransitionDirection?
    var durationFrames: Int
    var previousOutgoingAudioFadeOut: Int = 0
    var previousIncomingAudioFadeIn: Int = 0
    var previousOutgoingAudioClipId: String?
    var previousIncomingAudioClipId: String?

    /// The cut frame the transition is centered on, derived live so moves stay valid. Nil when
    /// the two clips are gone or no longer adjacent — a stale transition still removes cleanly.
    func boundary(in timeline: Timeline) -> Int? {
        guard let outgoing = timeline.tracks.flatMap(\.clips).first(where: { $0.id == outgoingClipId }),
              let incoming = timeline.tracks.flatMap(\.clips).first(where: { $0.id == incomingClipId })
        else { return nil }
        guard incoming.startFrame == outgoing.endFrame else { return nil }
        return incoming.startFrame
    }

    var receipt: [String: Any] {
        var out: [String: Any] = [
            "transitionId": id,
            "outgoingClipId": outgoingClipId,
            "incomingClipId": incomingClipId,
            "trackId": trackId,
            "type": type.rawValue,
            "durationFrames": durationFrames,
        ]
        if let direction { out["direction"] = direction.rawValue }
        if !overlayClipIds.isEmpty { out["overlayClipIds"] = overlayClipIds }
        return out
    }
}

enum TransitionValidationError: Error, Equatable {
    case unknownClip(String)
    case notAdjacent
    case differentTracks
    case unsupportedMedia(String)
    case multicam
    case existingTransition
    case conflictingKeyframes(String)
    case durationTooLong(maximum: Int)
    case insufficientHandles(frames: Int)
    case directionRequired
    case directionForbidden
    case unknownTransition(String)
    case invalidDuration
    case unknownType(String)
}

extension TransitionValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unknownClip(let id):
            "Clip not found: \(id)."
        case .notAdjacent:
            "The two clips must be adjacent with no gap — the incoming clip must start exactly where the outgoing clip ends."
        case .differentTracks:
            "Both clips must be on the same track."
        case .unsupportedMedia(let type):
            "Transitions need video or image clips (got \(type)). Audio crossfades belong to a dedicated audio tool."
        case .multicam:
            "Multicam clips cannot take transitions; switch the angle first."
        case .existingTransition:
            "One of these clips already has a transition. Remove it before applying another."
        case .conflictingKeyframes(let clip):
            "Clip \(clip) already has opacity keyframes, which a transition would overwrite. Clear them first."
        case .durationTooLong(let maximum):
            "The transition does not fit: at most \(maximum) frames fit here."
        case .insufficientHandles(let frames):
            "The incoming clip needs \(frames) frames of unused source before its start for the overlap. Use a shorter duration."
        case .directionRequired:
            "Slide and push need a direction: left, right, up, or down."
        case .directionForbidden:
            "Dissolve and dip-to-black take no direction."
        case .unknownTransition(let id):
            "Unknown transitionId '\(id)'."
        case .invalidDuration:
            "durationFrames must be at least 2."
        case .unknownType(let type):
            "Unknown transition type '\(type)'. Use one of: dissolve, dipToBlack, slide, push."
        }
    }
}
