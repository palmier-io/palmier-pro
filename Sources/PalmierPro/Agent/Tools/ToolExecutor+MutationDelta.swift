import Foundation

// Clip mutations return timeline diffs using get_timeline format, showing changed, shifted, or removed clips.
extension ToolExecutor {
    struct ClipPlacement {
        let trackId: String
        let index: Int
        let start: Int
        let duration: Int

        func samePlace(as other: ClipPlacement) -> Bool {
            trackId == other.trackId && start == other.start && duration == other.duration
        }
    }

    struct TimelineSnapshot {
        let placements: [String: ClipPlacement]
        let trackIds: [String]
    }

    private static let mutationClipLimit = 30
    private static let shiftGroupMinimum = 3

    func timelineSnapshot(_ editor: EditorViewModel) -> TimelineSnapshot {
        var placements: [String: ClipPlacement] = [:]
        for (i, track) in editor.timeline.tracks.enumerated() {
            for clip in track.clips {
                placements[clip.id] = ClipPlacement(trackId: track.id, index: i, start: clip.startFrame, duration: clip.durationFrames)
            }
        }
        return TimelineSnapshot(placements: placements, trackIds: editor.timeline.tracks.map(\.id))
    }

    func mutationResult(
        _ editor: EditorViewModel,
        since snapshot: TimelineSnapshot,
        touched: [String] = [],
        extra: [String: Any] = [:],
        notes: [String] = []
    ) -> ToolResult {
        let after = timelineSnapshot(editor)
        var notes = notes

        var changed = Set(touched.filter { after.placements[$0] != nil })
        changed.formUnion(after.placements.keys.filter { snapshot.placements[$0] == nil })
        var pureShifts: [String: (from: Int, delta: Int)] = [:]
        for (id, p) in after.placements {
            guard let b = snapshot.placements[id], !b.samePlace(as: p), !changed.contains(id) else { continue }
            if b.trackId == p.trackId && b.duration == p.duration {
                pureShifts[id] = (b.start, p.start - b.start)
            } else {
                changed.insert(id)
            }
        }

        // Uniform moves compress to rules; tiny groups enumerate instead.
        var shifts: [[String: Any]] = []
        let grouped = Dictionary(grouping: pureShifts.keys) { id -> String in
            "\(after.placements[id]!.index)|\(pureShifts[id]!.delta)"
        }
        for ids in grouped.values {
            if ids.count >= Self.shiftGroupMinimum {
                let first = pureShifts[ids[0]]!
                shifts.append([
                    "track": after.placements[ids[0]]!.index,
                    "fromFrame": ids.map { pureShifts[$0]!.from }.min() ?? first.from,
                    "by": first.delta,
                    "count": ids.count,
                ])
            } else {
                changed.formUnion(ids)
            }
        }
        shifts.sort { (($0["track"] as? Int) ?? 0, ($0["fromFrame"] as? Int) ?? 0) < (($1["track"] as? Int) ?? 0, ($1["fromFrame"] as? Int) ?? 0) }

        var payload = extra
        let captionGroups = collapseCaptionGroups(editor, changed: &changed)
        if !captionGroups.isEmpty { payload["captionGroups"] = captionGroups }
        var clips = readShapedClips(editor, ids: changed)
        if clips.count > Self.mutationClipLimit {
            payload["clipsNote"] = "Showing \(Self.mutationClipLimit) of \(clips.count) changed clips — re-read get_timeline for the rest."
            clips = Array(clips.prefix(Self.mutationClipLimit))
        }
        if !clips.isEmpty { payload["clips"] = clips }
        if !shifts.isEmpty { payload["shifted"] = shifts }

        let removedIds = snapshot.placements.keys.filter { after.placements[$0] == nil }.sorted()
        if !removedIds.isEmpty { payload["removedClipIds"] = removedIds }

        let created = after.trackIds.enumerated()
            .filter { !snapshot.trackIds.contains($0.element) }
            .map { i, _ -> [String: Any] in
                ["index": i, "label": editor.timelineTrackDisplayLabel(at: i), "type": editor.timeline.tracks[i].type.rawValue]
            }
        if !created.isEmpty { payload["createdTracks"] = created }
        // Track index changes invalidate index-based calls unless new order is included.
        let afterTrackIds = Set(after.trackIds)
        let trackListChanged = snapshot.trackIds.contains { !afterTrackIds.contains($0) }
            || after.trackIds.enumerated().contains { i, id in
                snapshot.trackIds.firstIndex(of: id).map { $0 != i } ?? false
            }
        if trackListChanged && payload["tracks"] == nil {
            notes.append("Track indices shifted — re-read get_timeline before the next index-based call.")
        }

        if !notes.isEmpty { payload["notes"] = notes }
        return .ok(Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) ?? "{}")
    }

    /// If 3+ changed clips share a captionGroupId, collapse to one group summary in get_timeline.
    private func collapseCaptionGroups(_ editor: EditorViewModel, changed: inout Set<String>) -> [[String: Any]] {
        var gidByMember: [String: String] = [:]
        var counts: [String: Int] = [:]
        for track in editor.timeline.tracks {
            for clip in track.clips where changed.contains(clip.id) {
                guard let gid = clip.captionGroupId else { continue }
                gidByMember[clip.id] = gid
                counts[gid, default: 0] += 1
            }
        }
        let collapsedGids = Set(counts.filter { $0.value >= Self.shiftGroupMinimum }.keys)
        guard !collapsedGids.isEmpty else { return [] }
        changed = changed.filter { gidByMember[$0].map { !collapsedGids.contains($0) } ?? true }

        guard let rawTracks = Self.rawTimelineDict(editor.timeline)?["tracks"] as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        for track in Self.compactTracks(rawTracks, editor: editor, window: nil, captionDetail: false) {
            for var group in track["captionGroups"] as? [[String: Any]] ?? [] {
                guard let gid = group["captionGroupId"] as? String, collapsedGids.contains(gid) else { continue }
                group["track"] = track["index"] ?? 0
                out.append(group)
            }
        }
        return out
    }

    /// Returns clips in get_timeline shape with track index, folding audio and captions.
    private func readShapedClips(_ editor: EditorViewModel, ids: Set<String>) -> [[String: Any]] {
        guard !ids.isEmpty,
              let rawTracks = Self.rawTimelineDict(editor.timeline)?["tracks"] as? [[String: Any]] else { return [] }
        let tracks = Self.compactTracks(rawTracks, editor: editor, window: nil, captionDetail: true)

        var byId: [String: [String: Any]] = [:]
        for track in tracks {
            let index = track["index"] as? Int ?? 0
            for var clip in track["clips"] as? [[String: Any]] ?? [] {
                clip["track"] = index
                if let id = clip["id"] as? String { byId[id] = clip }
                if let audio = clip["audio"] as? [String: Any], let aid = audio["id"] as? String {
                    byId[aid] = clip
                }
            }
            for group in track["captionGroups"] as? [[String: Any]] ?? [] {
                for row in group["clips"] as? [[Any]] ?? [] where row.count >= 4 {
                    guard let id = row[0] as? String else { continue }
                    byId[id] = [
                        "id": id, "track": index, "frames": [row[1], row[2]],
                        "textContent": row[3], "captionGroupId": group["captionGroupId"] ?? "",
                    ]
                }
            }
        }

        // Caption rows are capped per group; echo over-cap clips straight from the model.
        for (index, track) in editor.timeline.tracks.enumerated() {
            for clip in track.clips where ids.contains(clip.id) && byId[clip.id] == nil {
                var entry: [String: Any] = [
                    "id": clip.id, "track": index,
                    "frames": [clip.startFrame, clip.startFrame + clip.durationFrames],
                ]
                if let text = clip.textContent { entry["textContent"] = text }
                if let gid = clip.captionGroupId { entry["captionGroupId"] = gid }
                byId[clip.id] = entry
            }
        }

        var seen = Set<String>()
        return ids.compactMap { byId[$0] }
            .filter { seen.insert(($0["id"] as? String) ?? "").inserted }
            .sorted {
                let a = ($0["track"] as? Int ?? 0, ($0["frames"] as? [Int])?.first ?? 0)
                let b = ($1["track"] as? Int ?? 0, ($1["frames"] as? [Int])?.first ?? 0)
                return a < b
            }
    }
}
