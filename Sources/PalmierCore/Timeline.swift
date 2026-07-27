import Foundation

/// Clip location inside track storage.
public struct ClipLocation: Equatable, Sendable {
    public let trackIndex: Int
    public let clipIndex: Int

    public init(trackIndex: Int, clipIndex: Int) {
        self.trackIndex = trackIndex
        self.clipIndex = clipIndex
    }
}

/// Written on tab switch and save, not live — playhead mutates every frame.
public struct TimelineViewState: Codable, Sendable, Equatable {
    public var playheadFrame: Int = 0
    /// Default zoom in pixels-per-frame. Matches the app's Defaults.pixelsPerFrame.
    public var zoomScale: Double = 4.0
    public var scrollOffsetX: Double = 0

    public init() {}

    public init(playheadFrame: Int = 0, zoomScale: Double = 4.0, scrollOffsetX: Double = 0) {
        self.playheadFrame = playheadFrame
        self.zoomScale = zoomScale
        self.scrollOffsetX = scrollOffsetX
    }
}

public struct Timeline: Codable, Sendable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var name: String = "Timeline 1"
    public var fps: Int = 30
    public var width: Int = 1920
    public var height: Int = 1080
    public var settingsConfigured: Bool = false
    public var folderId: String?
    public var tracks: [Track] = []

    public init() {}

    /// Convenience init overriding just the name; id/fps/size default.
    public init(name: String) {
        self.init()
        self.name = name
    }

    public var totalFrames: Int {
        var maxFrame = 0
        for track in tracks {
            maxFrame = max(maxFrame, track.endFrame)
        }
        return maxFrame
    }

    public var hasAudioClips: Bool {
        tracks.contains { $0.type == .audio && !$0.clips.isEmpty }
    }

    /// Reachable nested timelines, breadth-first, deduped, excluding self and filtered by `include`.
    public func reachableTimelines(
        resolve: (String) -> Timeline?,
        maxDepth: Int = Int.max,
        include: (Timeline) -> Bool = { _ in true }
    ) -> [Timeline] {
        var found: [Timeline] = []
        var seen: Set<String> = [id]
        var queue: [(t: Timeline, depth: Int)] = [(self, 0)]
        var i = 0
        while i < queue.count {
            let (t, depth) = queue[i]
            i += 1
            guard depth < maxDepth else { continue }
            for clip in t.tracks.flatMap(\.clips) where clip.sourceClipType == .sequence {
                guard seen.insert(clip.mediaRef).inserted,
                      let child = resolve(clip.mediaRef), include(child) else { continue }
                found.append(child)
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fps, width, height, settingsConfigured, folderId, tracks
    }
}

public extension Timeline {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Timeline 1"
        self.fps = try c.decode(Int.self, forKey: .fps)
        self.width = try c.decode(Int.self, forKey: .width)
        self.height = try c.decode(Int.self, forKey: .height)
        self.settingsConfigured = (try? c.decode(Bool.self, forKey: .settingsConfigured)) ?? false
        self.folderId = try? c.decode(String.self, forKey: .folderId)
        self.tracks = try c.decode([Track].self, forKey: .tracks)
    }
}

public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var type: ClipType
    public var muted: Bool = false
    public var hidden: Bool = false
    public var syncLocked: Bool = true
    public var clips: [Clip] = []

    /// Persisted UI track height in points. Typed as Double (CGFloat is Double
    /// on 64-bit); clamped to [32, 200] on decode to match the app's TrackSize.
    public var displayHeight: Double = 50

    public init(
        id: String = UUID().uuidString,
        type: ClipType,
        muted: Bool = false,
        hidden: Bool = false,
        syncLocked: Bool = true,
        clips: [Clip] = [],
        displayHeight: Double = 50
    ) {
        self.id = id
        self.type = type
        self.muted = muted
        self.hidden = hidden
        self.syncLocked = syncLocked
        self.clips = clips
        self.displayHeight = displayHeight
    }

    public var endFrame: Int {
        var maxFrame = 0
        for clip in clips {
            maxFrame = max(maxFrame, clip.endFrame)
        }
        return maxFrame
    }

    /// Returns IDs of clips forming a contiguous chain starting at `fromEnd`, excluding `excludeId`.
    public func contiguousClipIds(fromEnd: Int, excludeId: String) -> Set<String> {
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
        case id, type, muted, hidden, syncLocked, clips, displayHeight
    }
}

public extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(ClipType.self, forKey: .type),
            muted: (try? c.decode(Bool.self, forKey: .muted)) ?? false,
            hidden: (try? c.decode(Bool.self, forKey: .hidden)) ?? false,
            syncLocked: (try? c.decode(Bool.self, forKey: .syncLocked)) ?? true,
            clips: (try? c.decode([Clip].self, forKey: .clips)) ?? [],
            displayHeight: (try? c.decode(Double.self, forKey: .displayHeight))
                .map { min(max($0, 32), 200) } ?? 50
        )
    }
}
