import AVFoundation

struct TrackMapping: @unchecked Sendable {
    enum Kind {
        case timeline(trackIndex: Int, clipIds: Set<String>?)
        case nested(clips: [Clip], carrier: Clip, parentTrackIndex: Int)
        case blackBackground(range: CMTimeRange)
    }
    let compositionTrack: AVMutableCompositionTrack
    let kind: Kind
    let naturalSize: CGSize   // zero for audio-only mappings
    let endTime: CMTime       // .zero for audio-only mappings
    let isVideo: Bool
    // Denoise blend: wet twin plays at strength volume, dry clip at 1-strength.
    var wetAudio = false
    var blendedClipIds: Set<String> = []
}

struct CompositionResult {
    let composition: AVMutableComposition
    let audioMix: AVMutableAudioMix
    let videoComposition: AVVideoComposition
    let trackMappings: [TrackMapping]
    let clipNaturalSizes: [String: CGSize]
    let clipTransforms: [String: CGAffineTransform]
    let offlineMediaRefs: Set<String>
    let unprocessableMediaRefs: Set<String>
    let preparedAudio: PreparedAudio
}

/// Builds an AVFoundation composition from a Timeline.
enum CompositionBuilder {

    struct InvalidTimelineError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Invalid timeline: \(reason)" }
    }

    @concurrent
    static func build(
        timeline: Timeline,
        resolveURL: @escaping @Sendable (String) -> URL?,
        resolveSourceSize: @escaping @Sendable (String) -> CGSize? = { _ in nil },
        resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
        missingMediaRefs: Set<String> = [],
        renderSize: CGSize,
        resolveAudioURL: (@Sendable (String) -> URL?)? = nil,
        makeAsset: @escaping @Sendable (URL) -> AVURLAsset = { AVURLAsset(url: $0) },
        loadTracks: @escaping @Sendable (AVURLAsset, AVMediaType) async throws -> [AVAssetTrack] = {
            try await $0.loadTracks(withMediaType: $1)
        }
    ) async throws -> CompositionResult {
        Log.preview.info("build fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height) tracks=\(timeline.tracks.count)")
        guard timeline.fps > 0, timeline.width > 0, timeline.height > 0 else {
            Log.preview.fault("build: invalid timeline fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
            throw InvalidTimelineError(reason: "fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
        }
        let preparedAudio = try await PreparedAudio.prepare(
            timeline: timeline, resolveTimeline: resolveTimeline,
            resolveURL: resolveAudioURL ?? resolveURL, missingMediaRefs: missingMediaRefs
        )
        let ctx = BuildContext(
            composition: AVMutableComposition(),
            timescale: CMTimeScale(timeline.fps),
            renderSize: renderSize,
            resolveURL: resolveURL,
            resolveSourceSize: resolveSourceSize,
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            makeAsset: makeAsset,
            loadTracks: loadTracks
        )
        ctx.preparedAudio = preparedAudio
        ctx.resolveAudioURL = resolveAudioURL

        for (trackIdx, track) in timeline.tracks.enumerated() {
            // Text is composited at render, not as a track.
            let sortedClips = track.clips
                .sorted { $0.startFrame < $1.startFrame }
                .filter { $0.mediaType != .text }
            guard !sortedClips.isEmpty else { continue }
            if track.type == .audio {
                guard !track.muted else { continue }
                try await insertAudioLane(clips: sortedClips, parentTrackIndex: trackIdx, nest: nil, depth: 0, ctx: ctx)
            } else {
                try await insertVideoLane(clips: sortedClips, parentTrackIndex: trackIdx, nestCarrier: nil, depth: 0, ctx: ctx)
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        // Opaque black background layer (bottommost) for full timeline
        let lastVideoEnd = ctx.trackMappings.filter(\.isVideo).map(\.endTime).max() ?? .zero
        let desiredDuration = max(CMTime(value: CMTimeValue(timeline.totalFrames), timescale: ctx.timescale), lastVideoEnd)
        if desiredDuration > .zero {
            if let mapping = try await insertBlackBackground(
                composition: ctx.composition,
                size: renderSize,
                range: CMTimeRange(start: .zero, duration: desiredDuration)
            ) {
                ctx.trackMappings.append(mapping)
            }
        }

        let (audioMix, videoComposition) = try await buildVisuals(
            timeline: timeline,
            trackMappings: ctx.trackMappings,
            clipNaturalSizes: ctx.clipNaturalSizes,
            clipTransforms: ctx.clipTransforms,
            resolveTimeline: resolveTimeline,
            compositionDuration: ctx.composition.duration,
            renderSize: renderSize,
            preparedAudio: preparedAudio
        )

        return CompositionResult(
            composition: ctx.composition,
            audioMix: audioMix,
            videoComposition: videoComposition,
            trackMappings: ctx.trackMappings,
            clipNaturalSizes: ctx.clipNaturalSizes,
            clipTransforms: ctx.clipTransforms,
            offlineMediaRefs: ctx.offlineMediaRefs,
            unprocessableMediaRefs: ctx.unprocessableMediaRefs,
            preparedAudio: preparedAudio
        )
    }

    /// Everything a build pass threads through insertion: inputs plus accumulators.
    private final class BuildContext {
        let composition: AVMutableComposition
        let timescale: CMTimeScale
        let renderSize: CGSize
        let resolveURL: @Sendable (String) -> URL?
        let resolveSourceSize: @Sendable (String) -> CGSize?
        let resolveTimeline: @Sendable (String) -> Timeline?
        let missingMediaRefs: Set<String>
        let makeAsset: @Sendable (URL) -> AVURLAsset
        let loadTracks: @Sendable (AVURLAsset, AVMediaType) async throws -> [AVAssetTrack]
        var trackMappings: [TrackMapping] = []
        var clipNaturalSizes: [String: CGSize] = [:]
        var clipTransforms: [String: CGAffineTransform] = [:]
        var offlineMediaRefs: Set<String> = []
        var unprocessableMediaRefs: Set<String> = []
        var sourceAssetsByURL: [URL: AVURLAsset] = [:]
        var trackLoadOutcomes: [TrackLoadKey: LoadOutcome] = [:]
        var videoURLsBySourceURL: [URL: URL] = [:]
        var loadOutcomesByMedia: [MediaLoadKey: LoadOutcome] = [:]
        var preparedAudio = PreparedAudio()
        var resolveAudioURL: (@Sendable (String) -> URL?)?

        init(
            composition: AVMutableComposition,
            timescale: CMTimeScale,
            renderSize: CGSize,
            resolveURL: @escaping @Sendable (String) -> URL?,
            resolveSourceSize: @escaping @Sendable (String) -> CGSize?,
            resolveTimeline: @escaping @Sendable (String) -> Timeline?,
            missingMediaRefs: Set<String>,
            makeAsset: @escaping @Sendable (URL) -> AVURLAsset,
            loadTracks: @escaping @Sendable (AVURLAsset, AVMediaType) async throws -> [AVAssetTrack]
        ) {
            self.composition = composition
            self.timescale = timescale
            self.renderSize = renderSize
            self.resolveURL = resolveURL
            self.resolveSourceSize = resolveSourceSize
            self.resolveTimeline = resolveTimeline
            self.missingMediaRefs = missingMediaRefs
            self.makeAsset = makeAsset
            self.loadTracks = loadTracks
        }

        private func sourceAsset(for url: URL) -> AVURLAsset {
            if let asset = sourceAssetsByURL[url] { return asset }
            let asset = makeAsset(url)
            sourceAssetsByURL[url] = asset
            return asset
        }

        func loadSource(for clip: Clip, mediaType: AVMediaType) async throws -> LoadOutcome {
            try Task.checkCancellation()
            let key = MediaLoadKey(mediaRef: clip.mediaRef, mediaType: mediaType)
            if let outcome = loadOutcomesByMedia[key] { return outcome }
            let outcome = try await prepareSource(for: clip, mediaType: mediaType)
            loadOutcomesByMedia[key] = outcome
            return outcome
        }

        private func prepareSource(for clip: Clip, mediaType: AVMediaType) async throws -> LoadOutcome {
            guard !missingMediaRefs.contains(clip.mediaRef) else { return .offline }
            let resolver = mediaType == .audio ? (resolveAudioURL ?? resolveURL) : resolveURL
            guard let resolvedURL = resolver(clip.mediaRef) else { return .offline }

            let mediaURL: URL
            if clip.mediaType == .image {
                let imageSize = resolveSourceSize(clip.mediaRef)
                    ?? ImageVideoGenerator.imageNativeSize(url: resolvedURL)
                    ?? renderSize
                do {
                    mediaURL = try await ImageVideoGenerator.stillVideo(
                        for: resolvedURL,
                        mediaRef: clip.mediaRef,
                        size: imageSize
                    )
                } catch {
                    Log.preview.error("stillVideo failed mediaRef=\(clip.mediaRef) size=\(Int(imageSize.width))x\(Int(imageSize.height)): \(Log.detail(error))")
                    return FileManager.default.fileExists(atPath: resolvedURL.path) ? .unprocessable : .offline
                }
            } else if clip.mediaType == .lottie {
                let lottieSize = resolveSourceSize(clip.mediaRef) ?? renderSize
                do {
                    mediaURL = try await LottieVideoGenerator.lottieVideo(
                        for: resolvedURL,
                        mediaRef: clip.mediaRef,
                        size: lottieSize
                    )
                } catch {
                    Log.preview.error("lottieVideo failed mediaRef=\(clip.mediaRef) size=\(Int(lottieSize.width))x\(Int(lottieSize.height)): \(Log.detail(error))")
                    return FileManager.default.fileExists(atPath: resolvedURL.path) ? .unprocessable : .offline
                }
            } else if mediaType == .video {
                return try await loadVideo(at: resolvedURL, clip: clip)
            } else {
                mediaURL = resolvedURL
            }
            return try await loadTrack(at: mediaURL, mediaType: mediaType, clip: clip)
        }

        private func loadTrack(
            at url: URL,
            mediaType: AVMediaType,
            clip: Clip
        ) async throws -> LoadOutcome {
            try Task.checkCancellation()
            let key = TrackLoadKey(url: url, mediaType: mediaType)
            if let outcome = trackLoadOutcomes[key] { return outcome }
            let asset = sourceAsset(for: key.url)
            let outcome: LoadOutcome
            do {
                if let track = try await loadTracks(asset, mediaType).first {
                    outcome = .loaded(asset: asset, track: track)
                } else {
                    outcome = .offline
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.preview.warning(
                    "loadTracks failed — skipping clip. clipId=\(clip.id) mediaRef=\(clip.mediaRef): \(error.localizedDescription)"
                )
                return .offline
            }
            trackLoadOutcomes[key] = outcome
            return outcome
        }

        private func loadVideo(at url: URL, clip: Clip) async throws -> LoadOutcome {
            let sourceURL = url.standardizedFileURL
            let source = try await loadTrack(at: sourceURL, mediaType: .video, clip: clip)
            guard case .loaded(let asset, let track) = source else { return source }

            let videoURL: URL
            if let cachedURL = videoURLsBySourceURL[sourceURL] {
                videoURL = cachedURL
            } else {
                do {
                    let normalizedURL = try await AlphaVideoNormalizer.premultipliedVideo(
                        for: sourceURL,
                        mediaRef: clip.mediaRef,
                        asset: asset,
                        track: track
                    )
                    try Task.checkCancellation()
                    videoURL = (normalizedURL ?? sourceURL).standardizedFileURL
                    videoURLsBySourceURL[sourceURL] = videoURL
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.preview.warning(
                        "alpha premultiply unavailable mediaRef=\(clip.mediaRef): \(error.localizedDescription)"
                    )
                    return source
                }
            }
            guard videoURL != sourceURL else { return source }
            return try await loadTrack(at: videoURL, mediaType: .video, clip: clip)
        }
    }

    /// One lane of video clips → at most one composition track; sequence clips expand recursively.
    private static func insertVideoLane(
        clips: [Clip],
        parentTrackIndex: Int,
        nestCarrier: Clip?,
        depth: Int,
        ctx: BuildContext
    ) async throws {
        var compTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var inserted: [Clip] = []
        var previousEndFrame = Int.min
        for clip in clips {
            guard clip.durationFrames > 0, clip.startFrame >= previousEndFrame else { continue }
            if clip.mediaType == .text { continue }   // text renders in instructions, nests render it in groups
            if clip.mediaType == .sequence {
                try await expandNestVideo(carrier: clip, parentTrackIndex: parentTrackIndex, depth: depth, ctx: ctx)
                previousEndFrame = clip.endFrame
                continue
            }
            let source: (asset: AVURLAsset, track: AVAssetTrack)
            switch try await ctx.loadSource(for: clip, mediaType: .video) {
            case .loaded(let asset, let track): source = (asset, track)
            case .offline: ctx.offlineMediaRefs.insert(clip.mediaRef); continue
            case .unprocessable: ctx.unprocessableMediaRefs.insert(clip.mediaRef); continue
            }
            if compTrack == nil {
                compTrack = ctx.composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track = compTrack else { continue }
            await recordSourceGeometry(for: clip, sourceTrack: source.track, ctx: ctx)
            if await insertClip(clip, sourceAsset: source.asset, sourceTrack: source.track,
                                into: track, cursor: &cursor, timescale: ctx.timescale) {
                inserted.append(clip)
                previousEndFrame = clip.endFrame
            }
        }
        guard let compTrack else { return }
        guard !inserted.isEmpty else {
            ctx.composition.removeTrack(compTrack)
            return
        }
        let naturalSize = (try? await compTrack.load(.naturalSize)).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? ctx.renderSize
        let kind: TrackMapping.Kind = nestCarrier.map { .nested(clips: inserted, carrier: $0, parentTrackIndex: parentTrackIndex) }
            ?? .timeline(trackIndex: parentTrackIndex, clipIds: Set(inserted.map(\.id)))
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack, kind: kind, naturalSize: naturalSize, endTime: cursor, isVideo: true
        ))
    }

    /// One lane of audio clips → at most one shared composition track (per-lane clips never overlap).
    private static func insertAudioLane(
        clips: [Clip],
        parentTrackIndex: Int,
        nest: (topCarrier: Clip, volumeScale: Double)?,
        depth: Int,
        ctx: BuildContext
    ) async throws {
        var compTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var inserted: [Clip] = []
        var blendedClipIds = Set<String>()
        var previousEndFrame = Int.min
        for var clip in clips {
            guard clip.durationFrames > 0, clip.startFrame >= previousEndFrame else { continue }
            previousEndFrame = clip.endFrame
            if clip.sourceClipType == .sequence {
                try await expandNestAudio(
                    carrier: clip,
                    topCarrier: nest?.topCarrier ?? clip,
                    volumeScale: nest.map { $0.volumeScale * clip.volume } ?? 1.0,
                    parentTrackIndex: parentTrackIndex, depth: depth, ctx: ctx
                )
                continue
            }
            if let nest { clip.volume *= nest.volumeScale }
            let source: (asset: AVURLAsset, track: AVAssetTrack)
            switch try await ctx.loadSource(for: clip, mediaType: .audio) {
            case .loaded(let asset, let track): source = (asset, track)
            case .offline: ctx.offlineMediaRefs.insert(clip.mediaRef); continue
            case .unprocessable: ctx.unprocessableMediaRefs.insert(clip.mediaRef); continue
            }
            if compTrack == nil {
                compTrack = ctx.composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track = compTrack else { continue }
            if await insertClip(clip, sourceAsset: source.asset, sourceTrack: source.track,
                                into: track, cursor: &cursor, timescale: ctx.timescale) {
                inserted.append(clip)
                if try await insertDenoisedTwin(clip, carrier: nest?.topCarrier, parentTrackIndex: parentTrackIndex, ctx: ctx) {
                    blendedClipIds.insert(clip.id)
                }
            }
        }
        guard let compTrack else { return }
        guard !inserted.isEmpty else {
            ctx.composition.removeTrack(compTrack)
            return
        }
        let kind: TrackMapping.Kind = nest.map { .nested(clips: inserted, carrier: $0.topCarrier, parentTrackIndex: parentTrackIndex) }
            ?? .timeline(trackIndex: parentTrackIndex, clipIds: Set(inserted.map(\.id)))
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack, kind: kind, naturalSize: .zero, endTime: .zero, isVideo: false,
            blendedClipIds: blendedClipIds
        ))
    }

    private static func insertDenoisedTwin(_ clip: Clip, carrier: Clip?, parentTrackIndex: Int, ctx: BuildContext) async throws -> Bool {
        let enhanceActive = clip.hasEnhanceEnabled && clip.enhanceAmount > 0
        guard (clip.hasDenoiseEnabled && clip.denoiseAmount > 0) || enhanceActive,
              let wetURL = ctx.preparedAudio.denoisedURLs[clip.mediaRef]
        else { return false }
        let asset = AVURLAsset(url: wetURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let compTrack = ctx.composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw AudioEnhancer.EnhanceError.noAudioTrack }
        var cursor = CMTime.zero
        guard await insertClip(
            clip, sourceAsset: asset, sourceTrack: sourceTrack,
            into: compTrack, cursor: &cursor, timescale: ctx.timescale
        ) else {
            ctx.composition.removeTrack(compTrack)
            throw AudioEnhancer.EnhanceError.writeFailed
        }
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack,
            kind: carrier.map { .nested(clips: [clip], carrier: $0, parentTrackIndex: parentTrackIndex) }
                ?? .timeline(trackIndex: parentTrackIndex, clipIds: [clip.id]),
            naturalSize: .zero,
            endTime: .zero,
            isVideo: false,
            wetAudio: true
        ))
        return true
    }

    private static func recordSourceGeometry(for clip: Clip, sourceTrack: AVAssetTrack, ctx: BuildContext) async {
        guard let natSize = try? await sourceTrack.load(.naturalSize), natSize.width > 0, natSize.height > 0 else { return }
        // Store clip display size and transform with origin at (0,0)
        let pt = (try? await sourceTrack.load(.preferredTransform)) ?? .identity
        let box = CGRect(origin: .zero, size: natSize).applying(pt)
        ctx.clipNaturalSizes[clip.id] = CGSize(width: abs(box.width), height: abs(box.height))
        ctx.clipTransforms[clip.id] = pt.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    private enum LoadOutcome {
        case loaded(asset: AVURLAsset, track: AVAssetTrack)
        case offline
        case unprocessable
    }

    private struct MediaLoadKey: Hashable {
        let mediaRef: String
        let mediaType: AVMediaType
    }

    private struct TrackLoadKey: Hashable {
        let url: URL
        let mediaType: AVMediaType

        init(url: URL, mediaType: AVMediaType) {
            self.url = url.standardizedFileURL
            self.mediaType = mediaType
        }
    }

    private static func insertClip(
        _ clip: Clip,
        sourceAsset: AVURLAsset,
        sourceTrack: AVAssetTrack,
        into compTrack: AVMutableCompositionTrack,
        cursor: inout CMTime,
        timescale: CMTimeScale
    ) async -> Bool {
        let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
        let sourceTimescale = (try? await sourceTrack.load(.naturalTimeScale)) ?? timescale
        let map = clip.timeMap
        let requestedSourceRange = CompositionSourceTiming.requestedRange(
            for: clip, timeMap: map, timescale: timescale, sourceTimescale: sourceTimescale
        )
        let trimStart = requestedSourceRange.start
        let clipDuration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: timescale)

        if clipStart > cursor {
            let gap = clipStart - cursor
            compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
        }

        // A ramp is inserted as one contiguous source range scaled piecewise, so a speed change
        // costs a few scaleTimeRange calls rather than a second composition track.
        let segments = map.segments
        guard !segments.isEmpty else { return false }
        var sourceDuration = requestedSourceRange.duration
        // Baked sources can be a hair shorter than the original; clamp instead of throwing.
        if let assetDuration = try? await sourceAsset.load(.duration), assetDuration.isNumeric {
            sourceDuration = CMTimeMinimum(sourceDuration, assetDuration - trimStart)
        }
        guard sourceDuration > .zero else { return false }
        let sourceRange = CMTimeRange(start: trimStart, duration: sourceDuration)

        do {
            try compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: clipStart)
        } catch {
            let srcSeconds = (try? await sourceAsset.load(.duration).seconds) ?? 0
            Log.preview.error("""
                insertTimeRange failed — skipping clip. \
                clipId=\(clip.id) mediaRef=\(clip.mediaRef) \
                trimStart=\(clip.trimStartFrame)f durationFrames=\(clip.durationFrames)f \
                speed=\(clip.speed) sourceSeconds=\(String(format: "%.3f", srcSeconds)) \
                error=\(error.localizedDescription)
                """)
            return false
        }

        // A single segment is the ordinary case: one linear scale, no per-segment work. A freeze
        // adds a segment even at constant speed, so segment count is the test, not constancy.
        if segments.count == 1 {
            if abs(map.averageSpeed - 1) > 0.0001
                || (sourceDuration == requestedSourceRange.duration && sourceDuration != clipDuration) {
                compTrack.scaleTimeRange(
                    CMTimeRange(start: clipStart, duration: sourceDuration),
                    toDuration: clipDuration
                )
            }
        } else {
            // scaleTimeRange rewrites the span it is given and shifts everything after it, so
            // walk back to front: scaling a later segment leaves earlier source offsets intact.
            for segment in segments.reversed() {
                let consumedBefore = map.sourceOffset(atTimelineOffset: segment.timelineRange.lowerBound)
                let sourceLength = CMTime(
                    seconds: segment.sourceSpan / Double(timescale),
                    preferredTimescale: timescale
                )
                let target = CMTime(
                    value: CMTimeValue(segment.timelineRange.count), timescale: timescale
                )
                guard sourceLength > .zero, target > .zero else { continue }
                // Media for this segment still sits where insertTimeRange put it: 1:1 from clipStart.
                let compStart = clipStart
                    + CMTime(seconds: consumedBefore / Double(timescale), preferredTimescale: timescale)
                let span = CMTimeRange(start: compStart, duration: sourceLength)
                guard compTrack.timeRange.intersection(span).duration > .zero else { continue }
                compTrack.scaleTimeRange(span, toDuration: target)
            }
        }

        cursor = clipStart + clipDuration
        return true
    }

    private static func insertBlackBackground(
        composition: AVMutableComposition,
        size: CGSize,
        range: CMTimeRange
    ) async throws -> TrackMapping? {
        let blackURL = try await ImageVideoGenerator.blackVideo(size: size)
        let asset = AVURLAsset(url: blackURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: range.duration),
            of: sourceTrack,
            at: range.start
        )
        return TrackMapping(
            compositionTrack: compTrack,
            kind: .blackBackground(range: range),
            naturalSize: size,
            endTime: range.end,
            isVideo: true
        )
    }

    private static func expandNestVideo(carrier: Clip, parentTrackIndex: Int, depth: Int, ctx: BuildContext) async throws {
        guard depth < NestFlattener.maxDepth else {
            Log.preview.warning("nest depth limit reached; skipping \(carrier.mediaRef.prefix(8))")
            return
        }
        guard let child = ctx.resolveTimeline(carrier.mediaRef) else {
            ctx.offlineMediaRefs.insert(carrier.mediaRef)
            return
        }
        let flat = NestFlattener.flatten(carrier: carrier, child: child, visual: true)
        for childClips in flat.videoTracks {
            try await insertVideoLane(clips: childClips, parentTrackIndex: parentTrackIndex,
                                      nestCarrier: carrier, depth: depth + 1, ctx: ctx)
        }
    }

    /// Static volumes fold down the chain; the top carrier's envelope multiplies at mix time.
    private static func expandNestAudio(
        carrier: Clip, topCarrier: Clip, volumeScale: Double,
        parentTrackIndex: Int, depth: Int, ctx: BuildContext
    ) async throws {
        guard depth < NestFlattener.maxDepth else {
            Log.preview.warning("nest depth limit reached; skipping \(carrier.mediaRef.prefix(8))")
            return
        }
        guard let child = ctx.resolveTimeline(carrier.mediaRef) else {
            ctx.offlineMediaRefs.insert(carrier.mediaRef)
            return
        }
        let flat = NestFlattener.flatten(carrier: carrier, child: child, visual: false)
        for trackClips in flat.audioTracks {
            try await insertAudioLane(clips: trackClips, parentTrackIndex: parentTrackIndex,
                                      nest: (topCarrier, volumeScale), depth: depth + 1, ctx: ctx)
        }
    }

    /// Rebuild only visual properties (transforms, opacity, volume)
    @concurrent
    static func buildVisuals(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize] = [:],
        clipTransforms: [String: CGAffineTransform] = [:],
        resolveTimeline: @Sendable (String) -> Timeline? = { _ in nil },
        compositionDuration: CMTime,
        renderSize: CGSize,
        preparedAudio: PreparedAudio = PreparedAudio()
    ) async throws -> (audioMix: AVMutableAudioMix, videoComposition: AVVideoComposition) {
        let timescale = CMTimeScale(timeline.fps)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = try trackMappings.filter { !$0.isVideo }.compactMap { mapping in
            switch mapping.kind {
            case .blackBackground:
                return nil
            case .nested(let clips, let carrier, let parentTrackIndex):
                let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
                guard timeline.tracks.indices.contains(parentTrackIndex) else { return params }
                let parentTrack = timeline.tracks[parentTrackIndex]
                if parentTrack.muted {
                    params.setVolume(0, at: .zero)
                    return params
                }
                // Prefer the live carrier so nest volume/fade edits apply on refresh.
                let liveCarrier = parentTrack.clips.first { $0.id == carrier.id } ?? carrier
                var ramps: [PlannedRamp] = []
                for clip in clips {
                    ramps += audioRamps(clip: clip, mapping: mapping, carrier: liveCarrier,
                                        timescale: timescale, preparedAudio: preparedAudio)
                }
                try applyAudioRamps(ramps, to: params)
                return params
            case .timeline(let trackIndex, let clipIds):
                guard timeline.tracks.indices.contains(trackIndex) else { return nil }
                let track = timeline.tracks[trackIndex]
                let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
                if track.muted {
                    params.setVolume(0, at: .zero)
                    return params
                }
                var prevEndFrame = Int.min
                var ramps: [PlannedRamp] = []
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    if let clipIds, !clipIds.contains(clip.id) { continue }
                    guard clip.durationFrames > 0, clip.startFrame >= prevEndFrame else { continue }
                    ramps += audioRamps(clip: clip, mapping: mapping, timescale: timescale, preparedAudio: preparedAudio)
                    prevEndFrame = clip.startFrame + clip.durationFrames
                }
                try applyAudioRamps(ramps, to: params)
                return params
            }
        }

        var vcConfig = AVVideoComposition.Configuration()
        vcConfig.renderSize = renderSize
        vcConfig.frameDuration = CMTime(value: 1, timescale: timescale)

        vcConfig.customVideoCompositorClass = CustomVideoCompositor.self
        vcConfig.instructions = compositorInstructions(
            timeline: timeline,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes,
            clipTransforms: clipTransforms,
            resolveTimeline: resolveTimeline,
            compositionDuration: compositionDuration,
            renderSize: renderSize
        )
        return (audioMix, AVVideoComposition(configuration: vcConfig))
    }

    /// One instruction per segment between clip boundaries, layers bottom → top.
    private static func compositorInstructions(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize],
        clipTransforms: [String: CGAffineTransform],
        resolveTimeline: @Sendable (String) -> Timeline? = { _ in nil },
        compositionDuration: CMTime,
        renderSize: CGSize
    ) -> [CompositorInstruction] {
        let timescale = CMTimeScale(timeline.fps)
        func cmTime(_ frame: Int) -> CMTime { CMTime(value: CMTimeValue(frame), timescale: timescale) }
        struct Slot { let trackID: CMPersistentTrackID; let natSize: CGSize; let transform: CGAffineTransform }
        struct Entry { let start: CMTime; let end: CMTime; let plan: LayerPlan }

        // Resolve each inserted media clip to the composition track it lives on.
        var media: [String: Slot] = [:]
        for mapping in trackMappings where mapping.isVideo {
            let ids: Set<String>
            switch mapping.kind {
            case .timeline(let trackIndex, let clipIds):
                guard timeline.tracks.indices.contains(trackIndex) else { continue }
                ids = clipIds ?? Set(timeline.tracks[trackIndex].clips.filter { $0.mediaType != .text }.map(\.id))
            case .nested(let clips, _, _):
                ids = Set(clips.map(\.id))
            case .blackBackground:
                continue
            }
            for id in ids {
                media[id] = Slot(
                    trackID: mapping.compositionTrack.trackID,
                    natSize: clipNaturalSizes[id] ?? mapping.naturalSize,
                    transform: clipTransforms[id] ?? .identity
                )
            }
        }

        // Flatten is pure per carrier — memoize; segments reuse one result.
        var flattenCache: [String: NestFlattener.Flattened] = [:]
        func flattened(for carrier: Clip, depth: Int) -> NestFlattener.Flattened? {
            guard depth < NestFlattener.maxDepth else { return nil }
            if let cached = flattenCache[carrier.id] { return cached }
            guard let child = resolveTimeline(carrier.mediaRef) else { return nil }
            let flat = NestFlattener.flatten(carrier: carrier, child: child, visual: true)
            flattenCache[carrier.id] = flat
            return flat
        }

        // Group layer for one segment window; empty children still render (nest gaps are opaque black).
        func nestGroupPlan(carrier: Clip, depth: Int, window: Range<Int>) -> LayerPlan? {
            guard let flat = flattened(for: carrier, depth: depth) else { return nil }
            var children: [LayerPlan] = []
            for childClips in flat.videoTracks.reversed() {
                var prevEnd = Int.min
                for clip in childClips where clip.durationFrames > 0 {
                    let overlapsWindow = clip.startFrame < window.upperBound && clip.endFrame > window.lowerBound
                    if clip.mediaType == .text {
                        guard overlapsWindow, !(clip.textContent ?? "").isEmpty else { continue }
                        children.append(LayerPlan(source: .text, clip: clip, natSize: flat.childCanvas, preferredTransform: .identity))
                    } else if clip.mediaType == .sequence {
                        guard clip.startFrame >= prevEnd else { continue }
                        prevEnd = clip.endFrame
                        guard overlapsWindow, let plan = nestGroupPlan(carrier: clip, depth: depth + 1, window: window) else { continue }
                        children.append(plan)
                    } else {
                        guard clip.startFrame >= prevEnd, let slot = media[clip.id] else { continue }
                        prevEnd = clip.endFrame
                        guard overlapsWindow else { continue }
                        children.append(LayerPlan(source: .track(slot.trackID), clip: clip, natSize: slot.natSize, preferredTransform: slot.transform))
                    }
                }
            }
            return LayerPlan(source: .group(children: children, canvas: flat.childCanvas),
                             clip: carrier, natSize: flat.childCanvas, preferredTransform: .identity)
        }

        // Child clip boundaries: segments scope decoder demand to what's visible.
        func nestCutFrames(carrier: Clip, depth: Int) -> [Int] {
            guard let flat = flattened(for: carrier, depth: depth) else { return [] }
            var frames: [Int] = []
            for childClips in flat.videoTracks {
                for clip in childClips {
                    frames.append(clip.startFrame)
                    frames.append(clip.endFrame)
                    if clip.mediaType == .sequence {
                        frames.append(contentsOf: nestCutFrames(carrier: clip, depth: depth + 1))
                    }
                }
            }
            return frames.filter { $0 > carrier.startFrame && $0 < carrier.endFrame }
        }

        // Walk tracks in reverse to produce bottom→top entries. Text layers follow track order.
        var entries: [Entry] = []
        for track in timeline.tracks.reversed() where !track.hidden {
            var prevEndFrame = Int.min
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) where clip.durationFrames > 0 {
                let plan: LayerPlan
                if clip.mediaType == .text {
                    guard !(clip.textContent ?? "").isEmpty else { continue }
                    plan = LayerPlan(source: .text, clip: clip, natSize: renderSize, preferredTransform: .identity)
                } else if clip.mediaType == .sequence {
                    guard clip.startFrame >= prevEndFrame else { continue }
                    prevEndFrame = clip.endFrame
                    // One entry per child-boundary segment: each requires only the
                    // source tracks visible in that segment.
                    let bounds = ([clip.startFrame, clip.endFrame] + nestCutFrames(carrier: clip, depth: 0))
                        .reduce(into: Set<Int>()) { $0.insert($1) }
                        .sorted()
                    for i in 0..<(bounds.count - 1) {
                        let window = bounds[i]..<bounds[i + 1]
                        guard window.count > 0,
                              let group = nestGroupPlan(carrier: clip, depth: 0, window: window) else { continue }
                        entries.append(Entry(start: cmTime(window.lowerBound), end: cmTime(window.upperBound), plan: group))
                    }
                    continue
                } else {
                    guard clip.startFrame >= prevEndFrame, let slot = media[clip.id] else { continue }
                    plan = LayerPlan(source: .track(slot.trackID), clip: clip, natSize: slot.natSize, preferredTransform: slot.transform)
                    prevEndFrame = clip.endFrame
                }
                entries.append(Entry(start: cmTime(clip.startFrame), end: cmTime(clip.endFrame), plan: plan))
            }
        }

        var cutSet = Set<CMTime>()
        for e in entries {
            cutSet.insert(e.start)
            cutSet.insert(e.end)
        }
        let cuts = cutSet.filter { $0 > .zero && $0 < compositionDuration }.sorted()
        let bounds = [.zero] + cuts + [compositionDuration]

        var startsByTime: [CMTime: [Int]] = [:]
        var endsByTime: [CMTime: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            startsByTime[entry.start, default: []].append(index)
            endsByTime[entry.end, default: []].append(index)
        }

        var active: [Int] = []
        var activeSet = Set<Int>()

        func insertActive(_ index: Int) {
            guard activeSet.insert(index).inserted else { return }
            var low = 0
            var high = active.count
            while low < high {
                let mid = (low + high) / 2
                if active[mid] < index {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            active.insert(index, at: low)
        }

        func removeActive(_ index: Int) {
            guard activeSet.remove(index) != nil else { return }
            var low = 0
            var high = active.count
            while low < high {
                let mid = (low + high) / 2
                if active[mid] < index {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low < active.count, active[low] == index {
                active.remove(at: low)
            }
        }

        for (index, entry) in entries.enumerated() where entry.start < .zero && entry.end > .zero {
            insertActive(index)
        }

        var instructions: [CompositorInstruction] = []
        instructions.reserveCapacity(max(0, bounds.count - 1))
        for i in 0..<(bounds.count - 1) {
            let start = bounds[i]
            for index in endsByTime[start] ?? [] { removeActive(index) }
            for index in startsByTime[start] ?? [] { insertActive(index) }

            let range = CMTimeRange(start: bounds[i], end: bounds[i + 1])
            guard range.duration > .zero else { continue }
            let layers = active.map { entries[$0].plan }
            instructions.append(CompositorInstruction(
                timeRange: range, layers: layers, renderSize: renderSize, fps: timeline.fps
            ))
        }
        return instructions
    }

    /// Smooth-curve subdivision count for non-linear keyframe segments.
    static let smoothSegments = 8

    /// Interior subdivision offsets for a smooth ramp between two frames (excluding endpoints).
    static func smoothSubdivisions(from a: Int, to b: Int) -> [Int] {
        guard b > a else { return [] }
        let span = Double(b - a)
        let raw = (1..<smoothSegments).map { a + Int((span * Double($0) / Double(smoothSegments)).rounded()) }
        return Array(Set(raw)).sorted()
    }

    /// Linear-ramp volume envelope; a nest `carrier` multiplies its envelope in.
    /// Attenuation over a detected region, in clip-relative frames. AVFoundation forbids two
    /// overlapping ramps on one parameters object and raises an Objective-C exception Swift
    /// cannot catch when they do, so a dip is folded into the envelope's own ramp run instead
    /// of being layered on top of it. Sampling the multiplier at the dip boundaries reproduces
    /// the same fade shape while keeping the emitted ranges contiguous and disjoint.
    struct AudioGainDip: Sendable {
        var start: Int
        var fadeInEnd: Int
        var fadeOutStart: Int
        var end: Int
        var gain: Float

        func multiplier(at frame: Int) -> Float {
            if frame <= start || frame >= end { return 1 }
            if frame < fadeInEnd {
                let t = Float(frame - start) / Float(max(1, fadeInEnd - start))
                return 1 + (gain - 1) * t
            }
            if frame <= fadeOutStart { return gain }
            let t = Float(frame - fadeOutStart) / Float(max(1, end - fadeOutStart))
            return gain + (1 - gain) * t
        }
    }

    static func gainDips(
        clip: Clip,
        timescale: CMTimeScale,
        regions: [BreathDetector.Region]?,
        depthDB: Double,
        fadeSeconds: Double
    ) -> [AudioGainDip] {
        guard depthDB.isFinite, depthDB < 0, timescale > 0, fadeSeconds.isFinite, fadeSeconds >= 0,
              let regions, !regions.isEmpty,
              (try? LoudnessAnalyzer.sourceRange(for: clip, fps: Int(timescale))) != nil else { return [] }
        let fps = Double(timescale)
        let dipGain = Float(VolumeScale.linearFromDb(depthDB))
        let fadeFrames = max(1, Int(min(Double(clip.durationFrames), fadeSeconds * fps).rounded()))

        var dips: [AudioGainDip] = []
        for region in regions {
            guard region.start.isFinite, region.end.isFinite, region.start >= 0, region.end > region.start else { continue }
            let s0 = max(region.start * fps, Double(clip.trimStartFrame))
            let s1 = min(region.end * fps, Double(clip.trimStartFrame + clip.sourceFramesConsumed))
            guard s1 > s0 else { continue }
            let map = clip.timeMap
            let startFrame = max(clip.startFrame, clip.startFrame
                + map.timelineOffset(forSourceOffset: s0 - Double(clip.trimStartFrame)))
            let endFrame = min(clip.endFrame, clip.startFrame
                + map.timelineOffset(forSourceOffset: s1 - Double(clip.trimStartFrame)))
            let t0 = startFrame
            let t1 = endFrame
            guard t1 > t0 else { continue }
            let fade = min(fadeFrames, (t1 - t0) / 2)
            let fadeInEnd = t0 + fade
            let fadeOutStart = t1 - fade
            dips.append(AudioGainDip(
                start: t0, fadeInEnd: fadeInEnd, fadeOutStart: fadeOutStart, end: t1, gain: dipGain
            ))
        }
        return dips
    }

    private static func audioRamps(
        clip: Clip, mapping: TrackMapping, carrier: Clip? = nil,
        timescale: CMTimeScale, preparedAudio: PreparedAudio
    ) -> [PlannedRamp] {
        let enhance = clip.hasEnhanceEnabled && clip.enhanceAmount > 0
        let strength = Float(enhance ? clip.enhanceAmount : (clip.hasDenoiseEnabled ? clip.denoiseAmount : 0))
        var gain: Float = mapping.wetAudio ? strength : (mapping.blendedClipIds.contains(clip.id) ? 1 - strength : 1)
        if clip.hasLoudnessMatchEnabled {
            gain *= Float(pow(10, clip.loudnessGainDB * (clip.hasEnhanceEnabled ? clip.enhanceAmount : 1) / 20))
        }
        var dips: [AudioGainDip] = []
        if enhance || clip.hasDebreathEnabled {
            dips += gainDips(
                clip: clip, timescale: timescale, regions: preparedAudio.breaths[clip.mediaRef],
                depthDB: -24 * (enhance ? clip.enhanceAmount : clip.debreathAmount), fadeSeconds: 0.03
            )
        }
        if enhance {
            dips += gainDips(
                clip: clip, timescale: timescale,
                regions: preparedAudio.sibilance[clip.mediaRef]?.map { .init(start: $0.start, end: $0.end) },
                depthDB: -12 * clip.enhanceDeess, fadeSeconds: 0.01
            )
        }
        var ramps: [PlannedRamp] = []
        emitVolumeEnvelope(clip: clip, timescale: timescale, carrier: carrier, gain: gain, dips: dips) {
            ramps.append(PlannedRamp(range: $0, from: $1, to: $2))
        }
        return ramps
    }

    /// A single planned volume ramp, in composition time.
    struct PlannedRamp: Sendable {
        let range: CMTimeRange
        let from: Float
        let to: Float
    }

    static func planVolumeRamps(
        clip: Clip,
        timescale: CMTimeScale,
        gain: Float = 1,
        dips: [AudioGainDip] = []
    ) -> [PlannedRamp] {
        var out: [PlannedRamp] = []
        emitVolumeEnvelope(
            clip: clip, timescale: timescale, gain: gain, dips: dips,
            collect: { range, from, to in out.append(PlannedRamp(range: range, from: from, to: to)) }
        )
        let headroom = audioHeadroom(for: out)
        return out.map { PlannedRamp(range: $0.range, from: $0.from / headroom, to: $0.to / headroom) }
    }

    private static func audioHeadroom(for ramps: [PlannedRamp]) -> Float {
        ramps.reduce(1) { max($0, $1.from, $1.to) }
    }

    private static func applyAudioRamps(_ ramps: [PlannedRamp], to parameters: AVMutableAudioMixInputParameters) throws {
        let headroom = audioHeadroom(for: ramps)
        if headroom > 1 { parameters.audioTapProcessor = try AudioGainTap.make(gain: headroom) }
        for ramp in ramps {
            parameters.setVolumeRamp(
                fromStartVolume: ramp.from / headroom, toEndVolume: ramp.to / headroom, timeRange: ramp.range
            )
        }
    }

    private static func emitVolumeEnvelope(
        clip: Clip,
        timescale: CMTimeScale,
        carrier: Clip? = nil,
        gain: Float = 1,
        dips: [AudioGainDip] = [],
        collect: ((CMTimeRange, Float, Float) -> Void)? = nil
    ) {
        let kfs = normalizedKeyframes(clip.volumeTrack?.keyframes ?? [], duration: clip.durationFrames)
        let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0
        let carrierVaries = carrier.map {
            ($0.volumeTrack?.isActive ?? false) || $0.fadeInFrames > 0 || $0.fadeOutFrames > 0
        } ?? false
        let gainAt: (Int) -> Double = { absFrame in
            carrier.map { $0.volumeAt(frame: absFrame) } ?? 1
        }
        if kfs.isEmpty && !hasFade && !carrierVaries && dips.isEmpty {
            let volume = max(0, Float(clip.volumeAt(frame: clip.startFrame) * gainAt(clip.startFrame)) * gain)
            let start = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
            let end = CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale)
            guard volume.isFinite, end > start else { return }
            let range = CMTimeRange(start: start, end: end)
            collect?(range, volume, volume)
            return
        }

        var extraOffsets: [Int] = []
        if let carrier, carrierVaries {
            let toClipOffset: (Int) -> Int = { carrierOffset in
                carrier.startFrame + carrierOffset - clip.startFrame
            }
            if carrier.fadeInFrames > 0 {
                extraOffsets.append(toClipOffset(carrier.fadeInFrames))
                if carrier.fadeInInterpolation == .smooth {
                    extraOffsets += smoothSubdivisions(from: 0, to: carrier.fadeInFrames).map(toClipOffset)
                }
            }
            if carrier.fadeOutFrames > 0 {
                let fadeStart = carrier.durationFrames - carrier.fadeOutFrames
                extraOffsets.append(toClipOffset(fadeStart))
                if carrier.fadeOutInterpolation == .smooth {
                    extraOffsets += smoothSubdivisions(from: fadeStart, to: carrier.durationFrames).map(toClipOffset)
                }
            }
            for kf in carrier.volumeTrack?.keyframes ?? [] {
                extraOffsets.append(toClipOffset(kf.frame))
            }
            for (a, b) in zip(carrier.volumeTrack?.keyframes ?? [], carrier.volumeTrack?.keyframes.dropFirst() ?? [])
            where a.interpolationOut == .hold {
                extraOffsets.append(toClipOffset(b.frame) - 1)
            }
            extraOffsets = extraOffsets.filter { $0 > 0 && $0 < clip.durationFrames }
        }

        for dip in dips {
            extraOffsets.append(dip.start - clip.startFrame)
            extraOffsets.append(dip.fadeInEnd - clip.startFrame)
            extraOffsets.append(dip.fadeOutStart - clip.startFrame)
            extraOffsets.append(dip.end - clip.startFrame)
        }

        emitEnvelopeRamps(
            clip: clip,
            kfs: kfs,
            timescale: timescale,
            extraOffsets: extraOffsets,
            sampleAt: { offset in
                let absolute = clip.startFrame + offset
                let base = Float(clip.volumeAt(frame: absolute) * gainAt(absolute)) * gain
                let attenuation = dips.reduce(1 as Float) { $0 * $1.multiplier(at: absolute) }
                return max(0, base * attenuation)
            },
            emit: { start, end, range in
                collect?(range, start, end)
            }
        )
    }


    /// Piecewise-linear envelope for the audio volume curve.
    private static func emitEnvelopeRamps(
        clip: Clip,
        kfs: [Keyframe<Double>],
        timescale: CMTimeScale,
        extraOffsets: [Int] = [],
        sampleAt: (Int) -> Float,
        emit: (Float, Float, CMTimeRange) -> Void
    ) {
        let dur = clip.durationFrames
        guard dur > 0 else { return }
        let kfs = normalizedKeyframes(kfs, duration: dur)

        var offsetSet: Set<Int> = [0, dur]
        offsetSet.formUnion(extraOffsets)
        for kf in kfs { offsetSet.insert(kf.frame) }
        for i in kfs.indices.dropLast() {
            let a = kfs[i], b = kfs[i + 1]
            switch a.interpolationOut {
            case .smooth: offsetSet.formUnion(smoothSubdivisions(from: a.frame, to: b.frame))
            case .hold:   if b.frame - a.frame > 1 { offsetSet.insert(b.frame - 1) }
            case .linear: break
            }
        }
        if clip.fadeInFrames > 0 {
            let endOffset = min(dur, clip.fadeInFrames)
            offsetSet.insert(endOffset)
            if clip.fadeInInterpolation == .smooth {
                offsetSet.formUnion(smoothSubdivisions(from: 0, to: endOffset))
            }
        }
        if clip.fadeOutFrames > 0 {
            let startOffset = max(0, dur - clip.fadeOutFrames)
            offsetSet.insert(startOffset)
            if clip.fadeOutInterpolation == .smooth {
                offsetSet.formUnion(smoothSubdivisions(from: startOffset, to: dur))
            }
        }

        let offsets = offsetSet.sorted()
        for i in offsets.indices.dropLast() {
            let aOff = offsets[i], bOff = offsets[i + 1]
            guard bOff > aOff else { continue }
            let aT = CMTime(value: CMTimeValue(clip.startFrame + aOff), timescale: timescale)
            let bT = CMTime(value: CMTimeValue(clip.startFrame + bOff), timescale: timescale)
            guard bT > aT else { continue }
            emit(sampleAt(aOff), sampleAt(bOff), CMTimeRange(start: aT, end: bT))
        }
    }

    private static func normalizedKeyframes<V: Codable & Sendable & Equatable>(
        _ keyframes: [Keyframe<V>],
        duration: Int
    ) -> [Keyframe<V>] {
        var keyed: [Int: Keyframe<V>] = [:]
        for kf in keyframes where kf.frame >= 0 && kf.frame <= duration {
            keyed[kf.frame] = kf
        }
        return keyed.values.sorted { $0.frame < $1.frame }
    }

    /// Maps a clip's Transform (in normalized 0–1 canvas coordinates) to the
    /// CGAffineTransform an AVFoundation layer instruction expects.
    static func affineTransform(for t: Transform, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        let tl = t.topLeft
        let sx = (renderSize.width / natSize.width) * t.width * (t.flipHorizontal ? -1 : 1)
        let sy = (renderSize.height / natSize.height) * t.height * (t.flipVertical ? -1 : 1)
        let tx = (t.flipHorizontal ? tl.x + t.width : tl.x) * renderSize.width
        let ty = (t.flipVertical ? tl.y + t.height : tl.y) * renderSize.height
        let placed = CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return placed.concatenating(canvasRotationTransform(for: t, renderSize: renderSize))
    }

    static func canvasRotationTransform(for t: Transform, renderSize: CGSize) -> CGAffineTransform {
        guard t.rotation != 0 else { return .identity }
        let cx = t.centerX * renderSize.width
        let cy = t.centerY * renderSize.height
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: t.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
    }

}
