import Foundation

struct Timeline: Codable, Sendable, Equatable {
    var fps: Int = 30
    var width: Int = 1920
    var height: Int = 1080
    var settingsConfigured: Bool = false
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
    var syncLocked: Bool = true
    var clips: [Clip] = []

    /// Display-only height, not serialized. Reset to default on project open.
    var displayHeight: CGFloat = 60

    /// Frame where the last clip ends
    var endFrame: Int {
        clips.map(\.endFrame).max() ?? 0
    }

    /// Returns IDs of clips forming a contiguous chain starting at `fromEnd`, excluding `excludeId`.
    func contiguousClipIds(fromEnd: Int, excludeId: String) -> Set<String> {
        var ids = Set<String>()
        var chainEnd = fromEnd
        for c in clips.sorted(by: { $0.startFrame < $1.startFrame }) where c.id != excludeId && c.startFrame >= fromEnd {
            if c.startFrame != chainEnd { break }
            chainEnd = c.endFrame
            ids.insert(c.id)
        }
        return ids
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, label, muted, hidden, syncLocked, clips
    }
}

extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(ClipType.self, forKey: .type),
            label: try c.decode(String.self, forKey: .label),
            muted: (try? c.decode(Bool.self, forKey: .muted)) ?? false,
            hidden: (try? c.decode(Bool.self, forKey: .hidden)) ?? false,
            syncLocked: (try? c.decode(Bool.self, forKey: .syncLocked)) ?? true,
            clips: (try? c.decode([Clip].self, forKey: .clips)) ?? []
        )
    }
}

struct Clip: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var mediaRef: String
    var mediaType: ClipType = .video
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

    /// Top-left corner in normalized canvas space (0–1).
    var topLeft: (x: Double, y: Double) {
        (x + width / 2.0 - 0.5, y + height / 2.0 - 0.5)
    }

    init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    init(topLeft tl: (x: Double, y: Double), width w: Double, height h: Double) {
        self.width = w
        self.height = h
        self.x = tl.x - w / 2.0 + 0.5
        self.y = tl.y - h / 2.0 + 0.5
    }

    /// Snap a value to canvas boundaries (0 or 1) within threshold.
    static func snapToBoundary(_ value: Double, threshold: Double) -> Double {
        if abs(value) < threshold { return 0 }
        if abs(value - 1) < threshold { return 1 }
        return value
    }

    /// Snap clip edges and center to canvas boundaries (0, 0.5, 1).
    mutating func snapToCanvasEdges(threshold: Double) {
        let tl = topLeft

        // Horizontal: snap left edge to 0, right edge to 1, or center to 0.5
        let snappedLeft = Self.snapToBoundary(tl.x, threshold: threshold)
        let snappedRight = Self.snapToBoundary(tl.x + width, threshold: threshold)
        if snappedLeft != tl.x {
            x -= (tl.x - snappedLeft)
        } else if snappedRight != tl.x + width {
            x -= (tl.x + width - snappedRight)
        } else if abs(x) < threshold {
            x = 0
        }

        // Vertical: snap top edge to 0, bottom edge to 1, or center to 0.5
        let tl2 = topLeft
        let snappedTop = Self.snapToBoundary(tl2.y, threshold: threshold)
        let snappedBottom = Self.snapToBoundary(tl2.y + height, threshold: threshold)
        if snappedTop != tl2.y {
            y -= (tl2.y - snappedTop)
        } else if snappedBottom != tl2.y + height {
            y -= (tl2.y + height - snappedBottom)
        } else if abs(y) < threshold {
            y = 0
        }
    }
}
