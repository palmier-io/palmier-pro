import Foundation

/// Snapshot of one copied clip plus its position relative to the copy anchor
struct ClipClipboardEntry: Sendable {
    let clip: Clip
    let trackOffset: Int
    let frameOffset: Int
    let sourceTrackId: String
    let sourceTrackType: ClipType
}

extension EditorViewModel {

    var canPasteClips: Bool { !clipClipboard.isEmpty }

    /// Snapshot the current selection into `clipClipboard`
    func copySelectedClipsToClipboard() {
        let ids = selectedClipIds
        guard !ids.isEmpty else { return }

        var captures: [(clip: Clip, trackIndex: Int, trackId: String, trackType: ClipType)] = []
        for id in ids {
            guard let loc = findClip(id: id) else { continue }
            let track = timeline.tracks[loc.trackIndex]
            let clip = track.clips[loc.clipIndex]
            captures.append((clip, loc.trackIndex, track.id, track.type))
        }
        guard !captures.isEmpty else { return }
        captures.sort { a, b in
            if a.trackIndex != b.trackIndex { return a.trackIndex < b.trackIndex }
            if a.clip.startFrame != b.clip.startFrame { return a.clip.startFrame < b.clip.startFrame }
            return a.clip.id < b.clip.id
        }
        let minTrack = captures[0].trackIndex
        let minStart = captures.map(\.clip.startFrame).min() ?? 0

        clipClipboard = captures.map { cap in
            ClipClipboardEntry(
                clip: cap.clip,
                trackOffset: cap.trackIndex - minTrack,
                frameOffset: cap.clip.startFrame - minStart,
                sourceTrackId: cap.trackId,
                sourceTrackType: cap.trackType
            )
        }
    }

    /// Keyboard paste: lands at the playhead
    func pasteClipsAtPlayhead() {
        guard let anchor = clipClipboard.first else { return }
        let destTrack: Int
        if let idx = timeline.tracks.firstIndex(where: { $0.id == anchor.sourceTrackId }),
           timeline.tracks[idx].type.isCompatible(with: anchor.clip.mediaType) {
            destTrack = idx
        } else if let fallback = timeline.tracks.firstIndex(where: { $0.type.isCompatible(with: anchor.clip.mediaType) }) {
            destTrack = fallback
        } else {
            return
        }
        pasteClips(atTrack: destTrack, atFrame: activeFrame)
    }

    /// Paste the clipboard at (trackIndex, startFrame) -> mouse pointer position
    func pasteClips(atTrack trackIndex: Int, atFrame startFrame: Int) {
        guard !clipClipboard.isEmpty else { return }
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let baseFrame = max(0, startFrame)

        var placements: [ClonePlacement] = []
        for entry in clipClipboard {
            let dstTrack = trackIndex + entry.trackOffset
            guard timeline.tracks.indices.contains(dstTrack) else { continue }
            let trackType = timeline.tracks[dstTrack].type
            guard trackType.isCompatible(with: entry.clip.mediaType) else { continue }
            placements.append(ClonePlacement(
                source: entry.clip,
                trackId: timeline.tracks[dstTrack].id,
                dstStart: baseFrame + entry.frameOffset
            ))
        }

        let actionName = placements.count == 1 ? "Paste Clip" : "Paste Clips"
        let newIds = cloneClipsAt(placements, actionName: actionName)
        if !newIds.isEmpty {
            selectedClipIds = Set(newIds)
        }
    }

    /// Option+drag landing: put a copy at the drop target
    func duplicateClipsToPositions(_ moves: [(clipId: String, toTrack: Int, toFrame: Int)]) {
        guard !moves.isEmpty else { return }

        var placements: [ClonePlacement] = []
        for m in moves {
            guard let loc = findClip(id: m.clipId),
                  timeline.tracks.indices.contains(m.toTrack) else { continue }
            let src = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            let dst = timeline.tracks[m.toTrack]
            guard dst.type.isCompatible(with: src.mediaType) else { continue }
            placements.append(ClonePlacement(
                source: src,
                trackId: dst.id,
                dstStart: max(0, m.toFrame)
            ))
        }

        let actionName = placements.count == 1 ? "Duplicate Clip" : "Duplicate Clips"
        let newIds = cloneClipsAt(placements, actionName: actionName)
        if !newIds.isEmpty {
            selectedClipIds = Set(newIds)
        }
    }
}

private struct ClonePlacement {
    let source: Clip
    let trackId: String
    let dstStart: Int
}

private extension EditorViewModel {

    /// Shared cloning core for paste + opt-drag-duplicate.
    func cloneClipsAt(_ placements: [ClonePlacement], actionName: String) -> [String] {
        guard !placements.isEmpty else { return [] }

        var groupCounts: [String: Int] = [:]
        for p in placements {
            if let g = p.source.linkGroupId { groupCounts[g, default: 0] += 1 }
        }
        var groupRemap: [String: String] = [:]

        var newIds: [String] = []
        withTimelineSwap(actionName: actionName) {
            for p in placements {
                guard let ti = timeline.tracks.firstIndex(where: { $0.id == p.trackId }) else { continue }
                clearRegion(trackIndex: ti, start: p.dstStart, end: p.dstStart + p.source.durationFrames, prune: false)
            }

            for p in placements {
                guard let ti = timeline.tracks.firstIndex(where: { $0.id == p.trackId }) else { continue }
                var clone = p.source
                clone.id = UUID().uuidString
                clone.startFrame = p.dstStart
                if let oldGroup = p.source.linkGroupId, (groupCounts[oldGroup] ?? 0) > 1 {
                    if let mapped = groupRemap[oldGroup] {
                        clone.linkGroupId = mapped
                    } else {
                        let new = UUID().uuidString
                        groupRemap[oldGroup] = new
                        clone.linkGroupId = new
                    }
                } else {
                    clone.linkGroupId = nil
                }
                timeline.tracks[ti].clips.append(clone)
                newIds.append(clone.id)
            }

            for i in timeline.tracks.indices { sortClips(trackIndex: i) }
            pruneEmptyTracks()
        }
        return newIds
    }
}
