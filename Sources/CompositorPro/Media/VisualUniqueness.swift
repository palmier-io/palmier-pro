import Foundation

struct VisualOccurrence: Sendable, Equatable {
    var mediaRef: String
    var clipIds: [String]
    var lane: [String]
    var startFrame: Int
    var endFrame: Int
    var sourceStart: Double
    var sourceEnd: Double
    var isImage: Bool
}

struct VisualReuseConflict: Sendable, Equatable {
    var sourceIds: [String]
    var occurrences: [VisualOccurrence]
}

struct VisualUniquenessIssue: Sendable, Equatable {
    var reason: String
    var clipId: String?
    var mediaRef: String?
}

struct VisualUniquenessReport: Sendable, Equatable {
    var occurrences: [VisualOccurrence] = []
    var conflicts: [VisualReuseConflict] = []
    var unresolved: [VisualUniquenessIssue] = []

    var knownIdentityReuseFree: Bool { conflicts.isEmpty && unresolved.isEmpty }

    var receipt: [String: Any] {
        [
            "scope": "retained_source_identity",
            "knownIdentityReuseFree": knownIdentityReuseFree,
            "deliveryVerified": false,
            "identityFreshness": "not_checked",
            "perceptualSimilarity": "not_checked",
            "faceInspection": "not_checked",
            "occurrenceCount": occurrences.count,
            "conflicts": conflicts.map { conflict in
                ["sourceIds": conflict.sourceIds, "occurrences": conflict.occurrences.map(Self.occurrenceReceipt),
                 "action": "replace_repeated_source"] as [String: Any]
            },
            "unresolved": unresolved.map { issue in
                var out: [String: Any] = ["reason": issue.reason]
                if let clipId = issue.clipId { out["clipId"] = clipId }
                if let mediaRef = issue.mediaRef { out["mediaRef"] = mediaRef }
                return out
            },
        ]
    }

    private static func occurrenceReceipt(_ occurrence: VisualOccurrence) -> [String: Any] {
        ["mediaRef": occurrence.mediaRef, "clipIds": occurrence.clipIds,
         "startFrame": occurrence.startFrame, "endFrame": occurrence.endFrame]
    }
}

enum VisualUniqueness {
    private static let maximumOccurrences = 100_000

    @concurrent
    static func audit(timeline: Timeline, timelines: [Timeline], manifest: MediaManifest) async throws -> VisualUniquenessReport {
        try Task.checkCancellation()
        var resolver: [String: Timeline] = [:]
        for value in timelines {
            guard resolver.updateValue(value, forKey: value.id) == nil else {
                return VisualUniquenessReport(unresolved: [.init(reason: "duplicate_timeline_id", clipId: nil, mediaRef: value.id)])
            }
        }
        resolver[timeline.id] = timeline
        var traversal = Traversal(timelines: resolver)
        try traversal.visit(timeline, path: [], lane: [], ancestors: [])
        let report = traversal.report
        return try await audit(occurrences: report.occurrences, manifest: manifest, unresolved: report.unresolved)
    }

    @concurrent
    static func audit(occurrences: [VisualOccurrence], manifest: MediaManifest,
                      unresolved: [VisualUniquenessIssue] = []) async throws -> VisualUniquenessReport {
        var media: [String: MediaManifestEntry] = [:]
        for entry in manifest.entries {
            guard media.updateValue(entry, forKey: entry.id) == nil else {
                return VisualUniquenessReport(unresolved: [.init(reason: "duplicate_media_ref", clipId: nil, mediaRef: entry.id)])
            }
        }
        var report = VisualUniquenessReport(occurrences: occurrences, unresolved: unresolved)
        report.occurrences = try coalesce(report.occurrences)
        var aliases = Aliases()
        var tokens: [String: [String]] = [:]
        for occurrence in report.occurrences {
            try Task.checkCancellation()
            guard tokens[occurrence.mediaRef] == nil else { continue }
            guard let entry = media[occurrence.mediaRef] else {
                report.unresolved.append(.init(reason: "missing_media", clipId: occurrence.clipIds.first, mediaRef: occurrence.mediaRef))
                tokens[occurrence.mediaRef] = ["media:\(occurrence.mediaRef)"]
                continue
            }
            var ids = ["media:\(entry.id)"]
            if let identity = entry.inputIdentity, identity.isValid { ids.append(identity.inputId) }
            else { report.unresolved.append(.init(reason: "missing_content_identity", clipId: occurrence.clipIds.first, mediaRef: entry.id)) }
            if let origin = entry.importInput?.origin { ids.append(origin.sourceId) }
            if entry.generationInput != nil || entry.type == .lottie {
                report.unresolved.append(.init(reason: "unresolved_derivative_lineage", clipId: occurrence.clipIds.first, mediaRef: entry.id))
            }
            tokens[entry.id] = ids
            for id in ids { aliases.join(ids[0], id) }
        }
        var groups: [String: [VisualOccurrence]] = [:]
        var sources: [String: Set<String>] = [:]
        for occurrence in report.occurrences {
            try Task.checkCancellation()
            let ids = tokens[occurrence.mediaRef] ?? ["media:\(occurrence.mediaRef)"]
            let root = aliases.root(ids[0])
            groups[root, default: []].append(occurrence)
            sources[root, default: []].formUnion(ids)
        }
        report.conflicts = groups.keys.sorted().compactMap { key in
            guard let occurrences = groups[key], occurrences.count > 1 else { return nil }
            return VisualReuseConflict(sourceIds: (sources[key] ?? []).sorted(), occurrences: occurrences)
        }
        try Task.checkCancellation()
        return report
    }

    private struct Traversal {
        let timelines: [String: Timeline]
        var report = VisualUniquenessReport()
        var admitted = 0

        mutating func visit(_ timeline: Timeline, path: [String], lane: [String], ancestors: Set<String>) throws {
            try Task.checkCancellation()
            guard !ancestors.contains(timeline.id), ancestors.count <= NestFlattener.maxDepth else {
                report.unresolved.append(.init(reason: "cyclic_or_excessive_nesting", clipId: path.last, mediaRef: timeline.id))
                return
            }
            guard (1...120).contains(timeline.fps) else {
                report.unresolved.append(.init(reason: "invalid_timeline_geometry", clipId: path.last, mediaRef: timeline.id))
                return
            }
            var next = ancestors
            next.insert(timeline.id)
            var clipIds = Set<String>()
            var trackIds = Set<String>()
            for track in timeline.tracks {
                try Task.checkCancellation()
                guard trackIds.insert(track.id).inserted else {
                    report.unresolved.append(.init(reason: "duplicate_track_id", clipId: path.last, mediaRef: timeline.id))
                    continue
                }
                guard track.type.isVisual, !track.hidden else { continue }
                for clip in track.clips {
                    try Task.checkCancellation()
                    admitted += 1
                    guard admitted <= VisualUniqueness.maximumOccurrences else {
                        report.unresolved.append(.init(reason: "occurrence_limit_exceeded", clipId: path.last, mediaRef: timeline.id))
                        return
                    }
                    guard clipIds.insert(clip.id).inserted else {
                        report.unresolved.append(.init(reason: "duplicate_clip_id", clipId: clip.id, mediaRef: clip.mediaRef))
                        continue
                    }
                    try visit(clip, path: path, lane: lane + [timeline.id, track.id], fps: timeline.fps, ancestors: next)
                }
            }
        }

        mutating func visit(_ clip: Clip, path: [String], lane: [String], fps: Int, ancestors: Set<String>) throws {
            let instanceId = (path + [clip.id]).joined(separator: "/")
            guard Self.validTiming(clip) else {
                report.unresolved.append(.init(reason: "invalid_clip_timing", clipId: instanceId, mediaRef: clip.mediaRef))
                return
            }
            guard clip.mediaType.isVisual, clip.mediaType != .text else { return }
            if clip.sourceClipType == .sequence {
                guard let child = timelines[clip.mediaRef] else {
                    report.unresolved.append(.init(reason: "missing_nested_timeline", clipId: instanceId, mediaRef: clip.mediaRef))
                    return
                }
                guard clip.speed == 1, clip.speedTrack == nil, clip.freezeFrames == 0,
                      child.tracks.allSatisfy({ $0.clips.allSatisfy(Self.validTiming) }) else {
                    report.unresolved.append(.init(reason: "unsupported_nested_timing", clipId: instanceId, mediaRef: clip.mediaRef))
                    return
                }
                guard !ancestors.contains(child.id), ancestors.count <= NestFlattener.maxDepth else {
                    report.unresolved.append(.init(reason: "cyclic_or_excessive_nesting", clipId: instanceId, mediaRef: child.id))
                    return
                }
                let flattened = NestFlattener.flatten(carrier: clip, child: child, visual: true)
                var expanded = child
                expanded.fps = fps
                expanded.tracks = zip(flattened.videoTrackIds, flattened.videoTracks).map { id, clips in
                    Track(id: id, type: .video, clips: clips)
                }
                // Flattened clip IDs already include the carrier path.
                try visit(expanded, path: path, lane: lane, ancestors: ancestors)
                return
            }
            guard [.video, .image, .lottie].contains(clip.mediaType) else {
                report.unresolved.append(.init(reason: "unsupported_visual_type", clipId: instanceId, mediaRef: clip.mediaRef))
                return
            }
            let isImage = clip.mediaType == .image
            let start = isImage ? 0 : Double(clip.trimStartFrame)
            let end = isImage ? 0 : start + clip.timeMap.sourceOffset(atTimelineOffset: clip.durationFrames)
            guard end.isFinite, end >= start else {
                report.unresolved.append(.init(reason: "invalid_source_timing", clipId: instanceId, mediaRef: clip.mediaRef))
                return
            }
            report.occurrences.append(.init(mediaRef: clip.mediaRef, clipIds: [instanceId], lane: lane,
                                            startFrame: clip.startFrame, endFrame: clip.endFrame,
                                            sourceStart: start, sourceEnd: end, isImage: isImage))
        }

        static func validTiming(_ clip: Clip) -> Bool {
            guard clip.startFrame >= 0, clip.durationFrames > 0, clip.durationFrames <= maxFrameArg,
                  clip.startFrame <= maxFrameArg - clip.durationFrames,
                  clip.trimStartFrame >= 0, clip.trimEndFrame >= 0,
                  clip.trimStartFrame <= maxFrameArg, clip.trimEndFrame <= maxFrameArg,
                  clip.speed.isFinite, (SourceTimeMap.minimumSpeed...SourceTimeMap.maximumSpeed).contains(clip.speed),
                  (0...clip.durationFrames).contains(clip.freezeFrames),
                  clip.trimStartFrame <= maxFrameArg - clip.durationFrames else { return false }
            return clip.speedTrack?.keyframes.allSatisfy {
                (0...clip.durationFrames).contains($0.frame) && $0.value.isFinite
                    && (SourceTimeMap.minimumSpeed...SourceTimeMap.maximumSpeed).contains($0.value)
            } ?? true
        }
    }

    private static func coalesce(_ values: [VisualOccurrence]) throws -> [VisualOccurrence] {
        let ordered = values.sorted {
            if $0.lane != $1.lane { return $0.lane.lexicographicallyPrecedes($1.lane) }
            if $0.startFrame != $1.startFrame { return $0.startFrame < $1.startFrame }
            return $0.clipIds.lexicographicallyPrecedes($1.clipIds)
        }
        var result: [VisualOccurrence] = []
        for value in ordered {
            try Task.checkCancellation()
            let canJoin = result.last.map { last in
                last.lane == value.lane && last.mediaRef == value.mediaRef && last.isImage == value.isImage
                    && last.endFrame == value.startFrame
                    && (value.isImage || (last.sourceEnd > last.sourceStart && value.sourceEnd > value.sourceStart
                                         && abs(last.sourceEnd - value.sourceStart) <= 0.5))
            } ?? false
            if canJoin {
                result[result.count - 1].endFrame = value.endFrame
                result[result.count - 1].sourceEnd = value.sourceEnd
                result[result.count - 1].clipIds.append(contentsOf: value.clipIds)
            } else { result.append(value) }
        }
        return result
    }

    private struct Aliases {
        var parents: [String: String] = [:]

        mutating func root(_ id: String) -> String {
            var value = id
            var path: [String] = []
            while let parent = parents[value], parent != value {
                path.append(value)
                value = parent
            }
            for item in path { parents[item] = value }
            return value
        }

        mutating func join(_ a: String, _ b: String) {
            let first = root(a)
            let second = root(b)
            if first != second { parents[max(first, second)] = min(first, second) }
        }
    }
}
