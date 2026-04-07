import Foundation

struct Timeline: Codable, Sendable, Equatable {
    var fps: Int = 30
    var width: Int = 1920
    var height: Int = 1080
    var tracks: [Track] = []

    /// Total duration in frames across all tracks
    var totalFrames: Int {
        tracks.map(\.endFrame).max() ?? 0
    }
}

struct Track: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: ClipType
    var label: String
    var muted: Bool = false
    var hidden: Bool = false
    var clips: [Clip] = []

    /// Display-only height, not serialized. Reset to default on project open.
    var displayHeight: CGFloat = 60

    /// Frame where the last clip ends
    var endFrame: Int {
        clips.map(\.endFrame).max() ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, label, muted, hidden, clips
    }
}

struct Clip: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var mediaRef: String
    var startFrame: Int
    var durationFrames: Int
    var trimStartFrame: Int = 0
    var trimEndFrame: Int = 0
    var speed: Double = 1.0
    var volume: Double = 1.0
    var opacity: Double = 1.0
    var transform: Transform = Transform()

    /// Frame where this clip ends on the timeline
    var endFrame: Int { startFrame + durationFrames }

    /// Source duration accounting for trim on both ends
    var sourceDurationFrames: Int { durationFrames + trimStartFrame + trimEndFrame }
}

struct Transform: Codable, Sendable, Equatable {
    var x: Double = 0       // 0 = left edge
    var y: Double = 0       // 0 = top edge
    var width: Double = 1   // 1 = full canvas width
    var height: Double = 1  // 1 = full canvas height
}
