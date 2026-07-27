import Foundation

/// Clip location inside track storage.
struct ClipLocation: Equatable, Sendable {
    let trackIndex: Int
    let clipIndex: Int
}

/// Written on tab switch and save, not live — playhead mutates every frame.
struct TimelineViewState: Codable, Sendable, Equatable {
    var playheadFrame: Int = 0
    var zoomScale: Double = Defaults.pixelsPerFrame
    var scrollOffsetX: Double = 0
}

struct Timeline: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = "Timeline 1"
    var fps: Int = 30
    var width: Int = 1920
    var height: Int = 1080
    var settingsConfigured: Bool = false
    var folderId: String?
    var tracks: [Track] = []

    var totalFrames: Int {
        var maxFrame = 0
        for track in tracks {
            maxFrame = max(maxFrame, track.endFrame)
        }
        return maxFrame
    }

    var hasAudioClips: Bool {
        tracks.contains { $0.type == .audio && !$0.clips.isEmpty }
    }

    /// Reachable nested timelines, breadth-first, deduped, excluding self and filtered by `include`.
    func reachableTimelines(
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

extension Timeline {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            name: (try? c.decode(String.self, forKey: .name)) ?? "Timeline 1",
            fps: try c.decode(Int.self, forKey: .fps),
            width: try c.decode(Int.self, forKey: .width),
            height: try c.decode(Int.self, forKey: .height),
            settingsConfigured: (try? c.decode(Bool.self, forKey: .settingsConfigured)) ?? false,
            folderId: try? c.decode(String.self, forKey: .folderId),
            tracks: try c.decode([Track].self, forKey: .tracks)
        )
    }
}

struct Track: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: ClipType
    var muted: Bool = false
    var hidden: Bool = false
    var syncLocked: Bool = true
    var clips: [Clip] = []

    var displayHeight: CGFloat = 50

    var endFrame: Int {
        var maxFrame = 0
        for clip in clips {
            maxFrame = max(maxFrame, clip.endFrame)
        }
        return maxFrame
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
        case id, type, muted, hidden, syncLocked, clips, displayHeight
    }
}

extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(ClipType.self, forKey: .type),
            muted: (try? c.decode(Bool.self, forKey: .muted)) ?? false,
            hidden: (try? c.decode(Bool.self, forKey: .hidden)) ?? false,
            syncLocked: (try? c.decode(Bool.self, forKey: .syncLocked)) ?? true,
            clips: (try? c.decode([Clip].self, forKey: .clips)) ?? [],
            displayHeight: (try? c.decode(CGFloat.self, forKey: .displayHeight))
                .map { min(max($0, TrackSize.minHeight), TrackSize.maxHeight) } ?? 50
        )
    }
}

// Clip and FadeEdge live in PalmierCore (Clip.swift) and are re-exported via
// @_exported import PalmierCore. Transform, Crop, and CropAspectLock likewise
// (Transform.swift).

