import Foundation

/// Clip-to-clip transition attached to the *incoming* clip at an edit point.
/// Geometry: the incoming clip overlaps the outgoing clip by `durationFrames`
/// (`outgoing.endFrame - incoming.startFrame == durationFrames`).
struct ClipTransition: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: String
    var durationFrames: Int

    init(id: String = UUID().uuidString, type: String, durationFrames: Int) {
        self.id = id
        self.type = type
        self.durationFrames = max(1, durationFrames)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, durationFrames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(String.self, forKey: .type),
            durationFrames: max(1, (try? c.decode(Int.self, forKey: .durationFrames)) ?? 1)
        )
    }
}

extension Clip {
    /// Media types that can participate in a clip-to-clip transition.
    var supportsTransition: Bool {
        switch mediaType {
        case .video, .image, .audio, .lottie: return true
        case .text, .sequence: return false
        }
    }

    /// Overlap length implied by an abutting or overlapped pair (0 when abutting/gapped).
    static func overlapFrames(outgoing: Clip, incoming: Clip) -> Int {
        max(0, outgoing.endFrame - incoming.startFrame)
    }

    /// True when `incoming.transition` matches the pair's current overlap.
    static func hasValidTransition(outgoing: Clip, incoming: Clip) -> Bool {
        guard let t = incoming.transition, TransitionRegistry.contains(t.type) else { return false }
        let overlap = overlapFrames(outgoing: outgoing, incoming: incoming)
        return overlap == t.durationFrames
            && incoming.startFrame < outgoing.endFrame
            && outgoing.startFrame < incoming.startFrame
            && t.durationFrames >= 1
            && t.durationFrames < outgoing.durationFrames
            && t.durationFrames < incoming.durationFrames
    }
}
