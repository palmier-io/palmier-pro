import AVFoundation
import Foundation

struct StoryboardPreviewResult: Sendable, Equatable {
    let url: URL
    let key: String
    let frameCount: Int
    let fps: Int
    let width: Int
    let height: Int
}

enum StoryboardPreviewRenderPhase: Sendable {
    case admitted
    case beforeExport(URL)
    case exported(URL)
}

enum StoryboardPreviewService {
    private static let gate = AsyncSemaphore(value: 1)
    private static let filenamePrefix = "storyboard-preview-"

    @concurrent
    static func render(
        _ snapshot: StoryboardPreviewSnapshot,
        observe: @escaping @Sendable (StoryboardPreviewRenderPhase) async throws -> Void = { _ in }
    ) async throws -> StoryboardPreviewResult {
        try Task.checkCancellation()
        try await gate.wait()
        let result: StoryboardPreviewResult
        do {
            result = try await renderAcquired(snapshot, observe: observe)
        } catch {
            await gate.signal()
            throw error
        }
        await gate.signal()
        do {
            try Task.checkCancellation()
            return result
        } catch {
            let failure = error
            do { try await remove(result) }
            catch { throw CleanupFailure(operationError: failure, cleanupError: error) }
            throw failure
        }
    }

    @concurrent
    static func remove(_ result: StoryboardPreviewResult) async throws {
        let url = result.url.standardizedFileURL
        guard url.isFileURL, url.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL,
              url.lastPathComponent.hasPrefix(filenamePrefix), url.pathExtension == "mp4" else {
            throw StoryboardPreviewError.unsupportedSource
        }
        try removeIfPresent(url)
    }

    @concurrent
    private static func renderAcquired(
        _ snapshot: StoryboardPreviewSnapshot,
        observe: @Sendable (StoryboardPreviewRenderPhase) async throws -> Void
    ) async throws -> StoryboardPreviewResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)\(UUID().uuidString).mp4")
        var ownedTemporaryURLs: [URL] = []
        do {
            try await observe(.admitted)
            try Task.checkCancellation()
            try validateLayout(snapshot)
            let identities = try await identifySources(snapshot)
            let key = try snapshot.verifiedKey(identities: identities)
            try await validatePlayback(snapshot)
            var timeline = snapshot.timeline
            var remappedRefs: [String: String] = [:]
            var urls: [String: URL] = [:]
            var referencedURLs: [String: URL] = [:]
            var sizes: [String: CGSize] = [:]
            for source in snapshot.sources {
                try Task.checkCancellation()
                let ref: String
                let inputURL: URL
                if source.type == .image {
                    guard let identity = identities[source.mediaRef] else {
                        throw StoryboardPreviewError.unavailableSource
                    }
                    ref = "preview-\(UUID().uuidString)-\(identity.contentSHA256)"
                    inputURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(filenamePrefix)\(UUID().uuidString)")
                        .appendingPathExtension(source.url.pathExtension)
                    ownedTemporaryURLs.append(inputURL)
                    try FileManager.default.copyItem(at: source.url, to: inputURL)
                    let copiedIdentity = try await MediaInputIdentityService.shared.identify(inputURL, force: true)
                    try Task.checkCancellation()
                    guard copiedIdentity.contentSHA256 == identity.contentSHA256 else {
                        throw StoryboardPreviewError.sourceMismatch
                    }
                    guard let size = ImageVideoGenerator.imageNativeSize(url: inputURL) else {
                        throw StoryboardPreviewError.unavailableSource
                    }
                    let proxySize = scaledSize(size)
                    sizes[ref] = proxySize
                    let proxyURL = try await ImageVideoGenerator.stillVideo(for: inputURL, mediaRef: ref, size: proxySize)
                    ownedTemporaryURLs.append(proxyURL)
                    try Task.checkCancellation()
                    referencedURLs[source.mediaRef] = proxyURL
                } else {
                    ref = source.mediaRef
                    inputURL = source.url
                    referencedURLs[source.mediaRef] = source.url
                }
                remappedRefs[source.mediaRef] = ref
                urls[ref] = inputURL
            }
            for trackIndex in timeline.tracks.indices {
                for clipIndex in timeline.tracks[trackIndex].clips.indices {
                    let ref = timeline.tracks[trackIndex].clips[clipIndex].mediaRef
                    guard let remapped = remappedRefs[ref] else { throw StoryboardPreviewError.unavailableSource }
                    timeline.tracks[trackIndex].clips[clipIndex].mediaRef = remapped
                }
            }
            let sourceURLs = urls
            let sourceSizes = sizes
            let renderSize = boundedSize(CGSize(width: timeline.width, height: timeline.height))
            let built = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { sourceURLs[$0] },
                resolveSourceSize: { sourceSizes[$0] },
                renderSize: renderSize
            )
            try Task.checkCancellation()
            try await validateComposition(built, snapshot: snapshot, referencedURLs: referencedURLs)
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw StoryboardPreviewError.renderIncomplete
            }
            session.videoComposition = built.videoComposition
            if snapshot.measured { session.audioMix = built.audioMix }
            let duration = CMTime(value: Int64(snapshot.frameCount), timescale: Int32(timeline.fps))
            session.timeRange = CMTimeRange(start: .zero, duration: duration)
            try await observe(.beforeExport(outputURL))
            try Task.checkCancellation()
            try await session.export(to: outputURL, as: .mp4)
            try await observe(.exported(outputURL))
            try Task.checkCancellation()
            try await validateEncodedOutput(outputURL, duration: duration, size: renderSize, measured: snapshot.measured)
            guard try await identifySources(snapshot) == identities else { throw StoryboardPreviewError.sourceMismatch }
            try Task.checkCancellation()
            do { try removeOwnedFiles(&ownedTemporaryURLs) }
            catch { throw CleanupFailure(operationError: StoryboardPreviewError.renderIncomplete, cleanupError: error) }
            try Task.checkCancellation()
            return StoryboardPreviewResult(url: outputURL, key: key, frameCount: snapshot.frameCount,
                fps: timeline.fps, width: Int(renderSize.width), height: Int(renderSize.height))
        } catch {
            var failure: any Error = error
            do { try removeIfPresent(outputURL) }
            catch { failure = CleanupFailure(operationError: failure, cleanupError: error) }
            do { try removeOwnedFiles(&ownedTemporaryURLs) }
            catch { failure = CleanupFailure(operationError: failure, cleanupError: error) }
            if Task.isCancelled, !(failure is CleanupFailure) { throw CancellationError() }
            throw failure
        }
    }

    private static func validateLayout(_ snapshot: StoryboardPreviewSnapshot) throws {
        let timeline = snapshot.timeline
        try EditPlan.validatedGeometry(fps: timeline.fps, width: timeline.width, height: timeline.height)
        guard timeline.fps == snapshot.plan.fps, timeline.width == snapshot.plan.width,
              timeline.height == snapshot.plan.height, !timeline.tracks.isEmpty,
              timeline.tracks.count == (snapshot.measured ? 2 : 1),
              snapshot.sources.count <= EditPlanLimits.maximumShots + 1,
              Set(snapshot.sources.map(\.mediaRef)).count == snapshot.sources.count else {
            throw StoryboardPreviewError.unsupportedLayout
        }
        let limit = timeline.fps * 1_800
        var clipIds: Set<String> = []
        for track in timeline.tracks {
            guard !track.hidden, !track.muted, track.type == .video || track.type == .audio else {
                throw StoryboardPreviewError.unsupportedLayout
            }
            var end = 0
            for clip in track.clips {
                guard clipIds.insert(clip.id).inserted, clip.startFrame == end, clip.durationFrames > 0,
                      clip.durationFrames <= limit, clip.startFrame <= limit - clip.durationFrames,
                      clip.trimStartFrame >= 0, clip.speed == 1, clip.speedTrack == nil, clip.freezeFrames == 0,
                      clip.mediaType == clip.sourceClipType,
                      track.type == .audio ? clip.mediaType == .audio : (clip.mediaType == .image || clip.mediaType == .video) else {
                    throw StoryboardPreviewError.unsupportedLayout
                }
                end = clip.endFrame
            }
            guard end > 0 else { throw StoryboardPreviewError.emptyStoryboard }
        }
        guard timeline.tracks[0].type == .video,
              timeline.tracks[0].clips.count <= EditPlanLimits.maximumShots,
              timeline.tracks[0].clips.count == snapshot.plan.shots.count,
              !snapshot.measured || (timeline.tracks[1].type == .audio && timeline.tracks[1].clips.count == 1
                && timeline.tracks[1].endFrame == timeline.tracks[0].endFrame),
              Set(timeline.tracks.flatMap(\.clips).map(\.mediaRef)) == Set(snapshot.sources.map(\.mediaRef)) else {
            throw StoryboardPreviewError.unsupportedLayout
        }
    }

    private static func identifySources(_ snapshot: StoryboardPreviewSnapshot) async throws -> [String: MediaInputIdentity] {
        var identities: [String: MediaInputIdentity] = [:]
        for source in snapshot.sources {
            try Task.checkCancellation()
            guard source.url.isFileURL else { throw StoryboardPreviewError.unavailableSource }
            guard source.type == .image || source.type == .video || source.type == .audio else {
                throw StoryboardPreviewError.unsupportedSource
            }
            guard source.duration.isFinite, source.duration >= 0 else { throw StoryboardPreviewError.sourceMismatch }
            let identity: MediaInputIdentity
            do { identity = try await MediaInputIdentityService.shared.identify(source.url, force: true) }
            catch is CancellationError { throw CancellationError() }
            catch { throw StoryboardPreviewError.unavailableSource }
            if let expected = source.expectedInputId, identity.inputId != expected { throw StoryboardPreviewError.sourceMismatch }
            if source.type == .audio {
                guard snapshot.measured, snapshot.plan.narration?.mediaRef == source.mediaRef,
                      snapshot.plan.narrationTiming?.sourceFingerprint == identity.contentSHA256 else {
                    throw StoryboardPreviewError.sourceMismatch
                }
                do { try snapshot.plan.validateNarrationAttachment(identity: identity) }
                catch { throw StoryboardPreviewError.sourceMismatch }
            }
            identities[source.mediaRef] = identity
        }
        return identities
    }

    private static func validatePlayback(_ snapshot: StoryboardPreviewSnapshot) async throws {
        let shots = snapshot.measured ? try snapshot.plan.resolvedShots() : snapshot.plan.shots
        guard Set(shots.map(\.id)).count == shots.count else { throw StoryboardPreviewError.unsupportedLayout }
        let shotsByID = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        let clipsBySource = Dictionary(grouping: snapshot.timeline.tracks.flatMap(\.clips), by: \.mediaRef)
        for source in snapshot.sources {
            try Task.checkCancellation()
            var duration = source.duration
            if source.type != .image {
                let asset = AVURLAsset(url: source.url)
                let measuredDuration = try await asset.load(.duration)
                guard measuredDuration.isNumeric, measuredDuration > .zero else { throw StoryboardPreviewError.unavailableSource }
                duration = measuredDuration.seconds
                let mediaType: AVMediaType = source.type == .audio ? .audio : .video
                guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
                    throw StoryboardPreviewError.unavailableSource
                }
                if source.type == .video {
                    let formats = try await track.load(.formatDescriptions)
                    guard !formats.isEmpty else { throw StoryboardPreviewError.unavailableSource }
                    for format in formats {
                        if CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool == true {
                            throw StoryboardPreviewError.unsupportedSource
                        }
                    }
                }
                if source.type == .audio, measuredDuration != snapshot.plan.narrationTiming?.duration.cmTime {
                    throw StoryboardPreviewError.sourceMismatch
                }
            }
            for clip in clipsBySource[source.mediaRef] ?? [] {
                try Task.checkCancellation()
                guard clip.mediaType == source.type else { throw StoryboardPreviewError.sourceMismatch }
                let shot: EditPlanShot
                if source.type == .audio {
                    guard clip.trimStartFrame == 0 else { throw StoryboardPreviewError.sourceMismatch }
                    shot = EditPlanShot(id: clip.id, title: "Narration", startFrame: clip.startFrame, endFrame: clip.endFrame)
                } else {
                    let prefix = "preview-scene:"
                    guard clip.id.hasPrefix(prefix), let original = shotsByID[String(clip.id.dropFirst(prefix.count))],
                          original.mediaRef == source.mediaRef, original.startFrame == clip.startFrame,
                          original.endFrame == clip.endFrame else { throw StoryboardPreviewError.sourceMismatch }
                    shot = original
                }
                let range: Range<Int>
                do { range = try PlanSourceRange.playback(shot: shot, fps: snapshot.timeline.fps, type: source.type, duration: duration) }
                catch { throw StoryboardPreviewError.sourceMismatch }
                guard range.lowerBound == clip.trimStartFrame, range.count == clip.durationFrames else {
                    throw StoryboardPreviewError.sourceMismatch
                }
            }
        }
    }

    private static func validateComposition(
        _ built: CompositionResult,
        snapshot: StoryboardPreviewSnapshot,
        referencedURLs: [String: URL]
    ) async throws {
        guard built.offlineMediaRefs.isEmpty, built.unprocessableMediaRefs.isEmpty else {
            throw StoryboardPreviewError.renderIncomplete
        }
        let fps = Int32(snapshot.timeline.fps)
        let duration = CMTime(value: Int64(snapshot.frameCount), timescale: fps)
        guard try await built.composition.load(.duration) == duration else { throw StoryboardPreviewError.renderIncomplete }
        var inserted: Set<String> = []
        var sourceTimescales: [SourceTrackReference: CMTimeScale] = [:]
        let sources = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.mediaRef, $0) })
        for mapping in built.trackMappings {
            try Task.checkCancellation()
            guard case .timeline(let index, let ids) = mapping.kind else { continue }
            guard snapshot.timeline.tracks.indices.contains(index), let ids, !mapping.wetAudio else {
                throw StoryboardPreviewError.renderIncomplete
            }
            let track = snapshot.timeline.tracks[index]
            guard mapping.isVideo == (track.type == .video), ids == Set(track.clips.map(\.id)),
                  inserted.isDisjoint(with: ids),
                  try await mapping.compositionTrack.load(.timeRange) == CMTimeRange(start: .zero, duration: duration) else {
                throw StoryboardPreviewError.renderIncomplete
            }
            guard let segments = mapping.compositionTrack.segments else { throw StoryboardPreviewError.renderIncomplete }
            var segmentIndex = 0
            for clip in track.clips {
                guard let source = sources[clip.mediaRef], let sourceURL = referencedURLs[clip.mediaRef] else {
                    throw StoryboardPreviewError.renderIncomplete
                }
                let target = CMTimeRange(start: CMTime(value: Int64(clip.startFrame), timescale: fps),
                    duration: CMTime(value: Int64(clip.durationFrames), timescale: fps))
                var cursor = target.start
                while segmentIndex < segments.count {
                    try Task.checkCancellation()
                    let segment = segments[segmentIndex]
                    let mapping = segment.timeMapping
                    if mapping.target.end <= target.start {
                        segmentIndex += 1
                        continue
                    }
                    if mapping.target.start >= target.end { break }
                    let overlap = mapping.target.intersection(target)
                    guard overlap.duration > .zero, !segment.isEmpty, mapping.source.isValid, mapping.source.duration.isNumeric,
                          mapping.source.duration > .zero, mapping.target.duration.isNumeric,
                          overlap.start == cursor,
                          segment.sourceURL?.standardizedFileURL == sourceURL.standardizedFileURL else {
                        throw StoryboardPreviewError.renderIncomplete
                    }
                    let reference = SourceTrackReference(url: sourceURL.standardizedFileURL, trackID: segment.sourceTrackID)
                    let sourceTimescale: CMTimeScale
                    if let cached = sourceTimescales[reference] {
                        sourceTimescale = cached
                    } else {
                        let asset = AVURLAsset(url: reference.url)
                        let mediaType: AVMediaType = source.type == .audio ? .audio : .video
                        guard let referencedTrack = try await asset.loadTracks(withMediaType: mediaType)
                            .first(where: { $0.trackID == reference.trackID }) else {
                            throw StoryboardPreviewError.renderIncomplete
                        }
                        sourceTimescale = try await referencedTrack.load(.naturalTimeScale)
                        guard sourceTimescale > 0 else { throw StoryboardPreviewError.renderIncomplete }
                        sourceTimescales[reference] = sourceTimescale
                    }
                    let requested = CompositionSourceTiming.requestedRange(
                        for: clip, timeMap: clip.timeMap, timescale: fps, sourceTimescale: sourceTimescale
                    )
                    let actualStart = CMTimeMapTimeFromRangeToRange(overlap.start, fromRange: mapping.target, toRange: mapping.source)
                    let actualEnd = CMTimeMapTimeFromRangeToRange(overlap.end, fromRange: mapping.target, toRange: mapping.source)
                    let expectedStart = CMTimeMapTimeFromRangeToRange(overlap.start, fromRange: target, toRange: requested)
                    let expectedEnd = CMTimeMapTimeFromRangeToRange(overlap.end, fromRange: target, toRange: requested)
                    guard actualStart == expectedStart, actualEnd == expectedEnd else {
                        throw StoryboardPreviewError.renderIncomplete
                    }
                    cursor = overlap.end
                    if mapping.target.end <= target.end { segmentIndex += 1 }
                    else { break }
                }
                guard cursor == target.end else { throw StoryboardPreviewError.renderIncomplete }
            }
            inserted.formUnion(ids)
        }
        guard inserted == Set(snapshot.timeline.tracks.flatMap(\.clips).map(\.id)) else {
            throw StoryboardPreviewError.renderIncomplete
        }
    }

    private static func validateEncodedOutput(_ url: URL, duration: CMTime, size: CGSize, measured: Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.duration) == duration,
              let video = try await asset.loadTracks(withMediaType: .video).first,
              try await video.load(.timeRange) == CMTimeRange(start: .zero, duration: duration),
              try await video.load(.naturalSize) == size else { throw StoryboardPreviewError.renderIncomplete }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard measured ? !audio.isEmpty : audio.isEmpty else { throw StoryboardPreviewError.renderIncomplete }
        if measured {
            guard let track = audio.first,
                  try await track.load(.timeRange) == CMTimeRange(start: .zero, duration: duration) else {
                throw StoryboardPreviewError.renderIncomplete
            }
        }
    }

    private static func boundedSize(_ size: CGSize) -> CGSize {
        let size = scaledSize(size)
        func even(_ value: CGFloat) -> CGFloat { max(2, floor(value / 2) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    private static func scaledSize(_ size: CGSize) -> CGSize {
        let scale = min(1, 1_024 / max(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    private static func removeOwnedFiles(_ urls: inout [URL]) throws {
        var failure: (any Error)?
        while let url = urls.popLast() {
            do { try removeIfPresent(url) }
            catch {
                if let previous = failure { failure = CleanupFailure(operationError: previous, cleanupError: error) }
                else { failure = error }
            }
        }
        if let failure { throw failure }
    }

    private struct SourceTrackReference: Hashable {
        let url: URL
        let trackID: CMPersistentTrackID
    }

    struct CleanupFailure: LocalizedError, Sendable {
        let operationError: any Error
        let cleanupError: any Error
        var errorDescription: String? {
            "\(operationError.localizedDescription) Preview cleanup failed: \(cleanupError.localizedDescription)"
        }
    }
}
