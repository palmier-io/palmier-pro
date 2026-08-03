import Foundation

struct ExportTimelineAnalyticsInput: Sendable {
    enum Scope: Sendable {
        case exportedTimeline(root: Timeline, resolveTimeline: @Sendable (String) -> Timeline?)
        case project(timelines: [Timeline], rootTimelineId: String?)
    }

    let scope: Scope
    let manifest: MediaManifest
    let exportFilename: String
}

enum ExportTimelineAnalyticsSnapshot {
    static let schemaVersion = 2

    private enum Provenance: String {
        case imported
        case generated = "palmier_generated"
        case upscaled = "ai_upscaled"
    }

    private struct Usage {
        var clipCount = 0, generatedCount = 0, upscaledCount = 0, importedCount = 0
        var duration = 0.0, generatedDuration = 0.0

        mutating func record(_ provenance: Provenance, frames: Int, fps: Int) {
            clipCount += 1
            let seconds = Double(max(0, frames)) / Double(max(1, fps))
            duration += seconds
            switch provenance {
            case .generated:
                generatedCount += 1
                generatedDuration += seconds
            case .upscaled: upscaledCount += 1
            case .imported: importedCount += 1
            }
        }

        var generatedRatio: Double { clipCount > 0 ? Double(generatedCount) / Double(clipCount) : 0 }
        var generatedDurationRatio: Double { duration > 0 ? generatedDuration / duration : 0 }

        var object: Analytics.Payload {
            [
                "clip_count": clipCount,
                "generated_clip_count": generatedCount,
                "upscaled_clip_count": upscaledCount,
                "imported_clip_count": importedCount,
                "generated_clip_ratio": generatedRatio,
                "generated_duration_ratio": generatedDurationRatio,
            ]
        }
    }

    private typealias AssetRef = (id: String, provenance: Provenance)

    private struct Builder {
        let entries: [String: MediaManifestEntry]
        var assetRefs: [String: AssetRef] = [:]
        var assets: [Analytics.Payload] = []
        var visual = Usage(), audio = Usage()

        mutating func clip(_ clip: Clip, fps: Int, timelineIds: [String: String]) -> Analytics.Payload? {
            guard clip.captionGroupId == nil else { return nil }
            let nested = clip.sourceClipType == .sequence
            let asset = nested || clip.mediaType == .text ? nil : asset(for: clip.mediaRef, fallbackType: clip.sourceClipType)
            if let asset {
                switch clip.mediaType {
                case .video, .image, .lottie: visual.record(asset.provenance, frames: clip.durationFrames, fps: fps)
                case .audio: audio.record(asset.provenance, frames: clip.durationFrames, fps: fps)
                case .text, .sequence: break
                }
            }

            var object: Analytics.Payload = [
                "start_frame": clip.startFrame,
                "duration_frames": clip.durationFrames,
                "trim_start_frame": clip.trimStartFrame,
                "trim_end_frame": clip.trimEndFrame,
                "speed": clip.speed.isFinite ? clip.speed : 1,
                "media_type": clip.mediaType.rawValue,
                "source_clip_type": clip.sourceClipType.rawValue,
            ]
            if let asset { object["asset_id"] = asset.id }
            if nested, let id = timelineIds[clip.mediaRef] { object["nested_timeline_id"] = id }
            return object
        }

        mutating func asset(for mediaRef: String, fallbackType: ClipType) -> AssetRef {
            if let existing = assetRefs[mediaRef] { return existing }
            let entry = entries[mediaRef]
            let provenance: Provenance = if let input = entry?.generationInput {
                input.upscaleSettings == nil ? .generated : .upscaled
            } else { .imported }
            let ref = (id: "asset_\(assets.count)", provenance: provenance)
            var object: Analytics.Payload = [
                "id": ref.id,
                "filename": entry.map(filename) ?? "unknown",
                "media_type": (entry?.type ?? fallbackType).rawValue,
                "provenance": provenance.rawValue,
            ]
            if let entry, let input = entry.generationInput {
                object["generation_type"] = input.upscaleSettings == nil ? entry.type.rawValue : "upscale"
                object["model"] = input.model
            }
            assetRefs[mediaRef] = ref
            assets.append(object)
            return ref
        }
    }

    static func analyticsProperties(from input: ExportTimelineAnalyticsInput) -> Analytics.Payload {
        let scope: String, rootId: String?, timelines: [Timeline]
        switch input.scope {
        case .exportedTimeline(let root, let resolve):
            scope = "exported_timeline"
            rootId = root.id
            timelines = [root] + root.reachableTimelines(resolve: resolve)
        case .project(let projectTimelines, let requestedRoot):
            scope = "project"
            timelines = projectTimelines
            let ids = Set(projectTimelines.map(\.id))
            rootId = requestedRoot.flatMap { ids.contains($0) ? $0 : nil } ?? projectTimelines.first?.id
        }

        var timelineIds: [String: String] = [:]
        for timeline in timelines where timelineIds[timeline.id] == nil {
            timelineIds[timeline.id] = "timeline_\(timelineIds.count)"
        }
        var entries: [String: MediaManifestEntry] = [:]
        for entry in input.manifest.entries where entries[entry.id] == nil { entries[entry.id] = entry }

        var builder = Builder(entries: entries)
        var trackCount = 0, clipCount = 0, captionGroupCount = 0, captionClipCount = 0
        let timelineObjects: [Analytics.Payload] = timelines.compactMap { timeline in
            guard let id = timelineIds[timeline.id] else { return nil }
            let tracks: [Analytics.Payload] = timeline.tracks.enumerated().map { index, track in
                let clips = track.clips.compactMap {
                    builder.clip($0, fps: timeline.fps, timelineIds: timelineIds)
                }
                let captions = captionGroups(track.clips)
                trackCount += 1
                clipCount += clips.count
                captionGroupCount += captions.count
                captionClipCount += captions.reduce(0) { $0 + ($1["caption_count"] as? Int ?? 0) }
                return [
                    "index": index,
                    "type": track.type.rawValue,
                    "muted": track.muted,
                    "hidden": track.hidden,
                    "sync_locked": track.syncLocked,
                    "clips": clips,
                    "caption_groups": captions,
                ]
            }
            return [
                "id": id,
                "is_root": timeline.id == rootId,
                "fps": timeline.fps,
                "width": timeline.width,
                "height": timeline.height,
                "duration_frames": timeline.totalFrames,
                "tracks": tracks,
            ]
        }

        let summary: Analytics.Payload = [
            "timeline_count": timelineObjects.count,
            "track_count": trackCount,
            "clip_count": clipCount,
            "caption_group_count": captionGroupCount,
            "caption_clip_count": captionClipCount,
            "visual": builder.visual.object,
            "audio": builder.audio.object,
        ]
        let exportFilename = sanitizedFilename(input.exportFilename)
        var object: Analytics.Payload = [
            "schema_version": schemaVersion,
            "scope": scope,
            "export_filename": exportFilename,
            "summary": summary,
            "assets": builder.assets,
            "timelines": timelineObjects,
        ]
        if let rootId, let alias = timelineIds[rootId] { object["root_timeline_id"] = alias }
        return [
            "export_filename": exportFilename,
            "timeline_snapshot_schema": schemaVersion,
            "timeline_count": timelineObjects.count,
            "track_count": trackCount,
            "clip_count": clipCount,
            "caption_group_count": captionGroupCount,
            "caption_clip_count": captionClipCount,
            "visual_clip_count": builder.visual.clipCount,
            "generated_visual_clip_count": builder.visual.generatedCount,
            "upscaled_visual_clip_count": builder.visual.upscaledCount,
            "imported_visual_clip_count": builder.visual.importedCount,
            "generated_visual_clip_ratio": builder.visual.generatedRatio,
            "generated_visual_duration_ratio": builder.visual.generatedDurationRatio,
            "timeline_snapshot": object,
        ]
    }

    private static func captionGroups(_ clips: [Clip]) -> [Analytics.Payload] {
        var order: [String] = []
        var groups: [String: (start: Int, end: Int, count: Int)] = [:]
        for clip in clips {
            guard let id = clip.captionGroupId else { continue }
            if let group = groups[id] {
                groups[id] = (min(group.start, clip.startFrame), max(group.end, clip.endFrame), group.count + 1)
            } else {
                order.append(id)
                groups[id] = (clip.startFrame, clip.endFrame, 1)
            }
        }
        return order.compactMap { groups[$0] }.map {
            [
                "start_frame": $0.start,
                "duration_frames": max(0, $0.end - $0.start),
                "caption_count": $0.count,
            ]
        }
    }

    private static func filename(_ entry: MediaManifestEntry) -> String {
        switch entry.source {
        case .external(let path): sanitizedFilename(path)
        case .project(let path): sanitizedFilename(path)
        }
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        let cleaned = basename.components(separatedBy: .controlCharacters).joined()
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(255))
    }
}
