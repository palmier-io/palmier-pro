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
}

/// Builds an AVFoundation composition from a Timeline.
enum CompositionBuilder {

    struct InvalidTimelineError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Invalid timeline: \(reason)" }
    }

    static func build(
        timeline: Timeline,
        resolveURL: @escaping @Sendable (String) -> URL?,
        resolveSourceSize: @escaping @Sendable (String) -> CGSize? = { _ in nil },
        resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
        missingMediaRefs: Set<String> = [],
        renderSize: CGSize
    ) async throws -> CompositionResult {
        Log.preview.info("build fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height) tracks=\(timeline.tracks.count)")
        guard timeline.fps > 0, timeline.width > 0, timeline.height > 0 else {
            Log.preview.fault("build: invalid timeline fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
            throw InvalidTimelineError(reason: "fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
        }
        let ctx = BuildContext(
            composition: AVMutableComposition(),
            timescale: CMTimeScale(timeline.fps),
            renderSize: renderSize,
            resolveURL: resolveURL,
            resolveSourceSize: resolveSourceSize,
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs
        )

        for (trackIdx, track) in timeline.tracks.enumerated() {
            // Text is composited at render, not as a track.
            let sortedClips = track.clips
                .sorted { $0.startFrame < $1.startFrame }
                .filter { $0.mediaType != .text }
            guard !sortedClips.isEmpty else { continue }
            if track.type == .audio {
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

        let (audioMix, videoComposition) = buildVisuals(
            timeline: timeline,
            trackMappings: ctx.trackMappings,
            clipNaturalSizes: ctx.clipNaturalSizes,
            clipTransforms: ctx.clipTransforms,
            resolveTimeline: resolveTimeline,
            compositionDuration: ctx.composition.duration,
            renderSize: renderSize
        )

        return CompositionResult(
            composition: ctx.composition,
            audioMix: audioMix,
            videoComposition: videoComposition,
            trackMappings: ctx.trackMappings,
            clipNaturalSizes: ctx.clipNaturalSizes,
            clipTransforms: ctx.clipTransforms,
            offlineMediaRefs: ctx.offlineMediaRefs,
            unprocessableMediaRefs: ctx.unprocessableMediaRefs
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
        var trackMappings: [TrackMapping] = []
        var clipNaturalSizes: [String: CGSize] = [:]
        var clipTransforms: [String: CGAffineTransform] = [:]
        var offlineMediaRefs: Set<String> = []
        var unprocessableMediaRefs: Set<String> = []

        init(
            composition: AVMutableComposition,
            timescale: CMTimeScale,
            renderSize: CGSize,
            resolveURL: @escaping @Sendable (String) -> URL?,
            resolveSourceSize: @escaping @Sendable (String) -> CGSize?,
            resolveTimeline: @escaping @Sendable (String) -> Timeline?,
            missingMediaRefs: Set<String>
        ) {
            self.composition = composition
            self.timescale = timescale
            self.renderSize = renderSize
            self.resolveURL = resolveURL
            self.resolveSourceSize = resolveSourceSize
            self.resolveTimeline = resolveTimeline
            self.missingMediaRefs = missingMediaRefs
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
            switch try await loadSource(clip: clip, mediaType: .video, ctx: ctx) {
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
            switch try await loadSource(clip: clip, mediaType: .audio, ctx: ctx) {
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
                if nest == nil, await insertDenoisedTwin(clip, parentTrackIndex: parentTrackIndex, ctx: ctx) {
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

    private static func insertDenoisedTwin(_ clip: Clip, parentTrackIndex: Int, ctx: BuildContext) async -> Bool {
        guard clip.hasDenoiseEnabled, clip.denoiseAmount > 0,
              let resolved = ctx.resolveURL(clip.mediaRef),
              let wetURL = AudioEnhancer.cachedDenoisedURL(for: resolved, mediaRef: clip.mediaRef)
        else { return false }
        let asset = AVURLAsset(url: wetURL)
        guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let compTrack = ctx.composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { return false }
        var cursor = CMTime.zero
        guard await insertClip(
            clip, sourceAsset: asset, sourceTrack: sourceTrack,
            into: compTrack, cursor: &cursor, timescale: ctx.timescale
        ) else {
            ctx.composition.removeTrack(compTrack)
            return false
        }
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack,
            kind: .timeline(trackIndex: parentTrackIndex, clipIds: [clip.id]),
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

    private static func loadSource(clip: Clip, mediaType: AVMediaType, ctx: BuildContext) async throws -> LoadOutcome {
        try await loadSource(
            clip: clip, mediaType: mediaType, resolveURL: ctx.resolveURL,
            resolveSourceSize: ctx.resolveSourceSize, missingMediaRefs: ctx.missingMediaRefs,
            renderSize: ctx.renderSize
        )
    }

    private enum LoadOutcome {
        case loaded(asset: AVURLAsset, track: AVAssetTrack)
        case offline
        case unprocessable
    }

    private static func loadSource(
        clip: Clip,
        mediaType: AVMediaType,
        resolveURL: @Sendable (String) -> URL?,
        resolveSourceSize: @Sendable (String) -> CGSize?,
        missingMediaRefs: Set<String>,
        renderSize: CGSize
    ) async throws -> LoadOutcome {
        let mediaURL: URL
        guard !missingMediaRefs.contains(clip.mediaRef) else { return .offline }
        guard let resolved = resolveURL(clip.mediaRef) else { return .offline }
        if clip.mediaType == .image {
            let imageSize = resolveSourceSize(clip.mediaRef)
                ?? ImageVideoGenerator.imageNativeSize(url: resolved)
                ?? renderSize
            do {
                mediaURL = try await ImageVideoGenerator.stillVideo(
                    for: resolved,
                    mediaRef: clip.mediaRef,
                    size: imageSize
                )
            } catch {
                Log.preview.error("stillVideo failed mediaRef=\(clip.mediaRef) size=\(Int(imageSize.width))x\(Int(imageSize.height)): \(Log.detail(error))")
                return FileManager.default.fileExists(atPath: resolved.path) ? .unprocessable : .offline
            }
        } else if clip.mediaType == .lottie {
            let lottieSize = resolveSourceSize(clip.mediaRef) ?? renderSize
            do {
                mediaURL = try await LottieVideoGenerator.lottieVideo(
                    for: resolved,
                    mediaRef: clip.mediaRef,
                    size: lottieSize
                )
            } catch {
                Log.preview.error("lottieVideo failed mediaRef=\(clip.mediaRef) size=\(Int(lottieSize.width))x\(Int(lottieSize.height)): \(Log.detail(error))")
                return FileManager.default.fileExists(atPath: resolved.path) ? .unprocessable : .offline
            }
        } else if mediaType == .video {
            mediaURL = (try? await AlphaVideoNormalizer.premultipliedVideo(for: resolved, mediaRef: clip.mediaRef)) ?? resolved
        } else {
            mediaURL = resolved
        }

        guard !Task.isCancelled else { throw CancellationError() }
        let sourceAsset = AVURLAsset(url: mediaURL)
        do {
            guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: mediaType).first else {
                return .offline
            }
            return .loaded(asset: sourceAsset, track: sourceTrack)
        } catch {
            Log.preview.error("loadTracks failed — skipping clip. clipId=\(clip.id) mediaRef=\(clip.mediaRef): \(error.localizedDescription)")
            return .offline
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
        let trimStartFrame = clip.mediaType == .image ? max(0, clip.trimStartFrame) : clip.trimStartFrame
        let sourceTimescale = (try? await sourceTrack.load(.naturalTimeScale)) ?? timescale
        let startSeconds = Double(trimStartFrame) / Double(timescale)
        let trimStart = CMTime(seconds: startSeconds, preferredTimescale: sourceTimescale)
        let clipDuration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: timescale)

        if clipStart > cursor {
            let gap = clipStart - cursor
            compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
        }

        let sourceFrames = clip.speed == 1.0
            ? clip.durationFrames
            : max(1, Int(Double(clip.durationFrames) * clip.speed))
        let durationSeconds = Double(sourceFrames) / Double(timescale)
        var sourceDuration = CMTime(seconds: durationSeconds, preferredTimescale: sourceTimescale)
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
        if clip.speed != 1.0 {
            compTrack.scaleTimeRange(CMTimeRange(start: clipStart, duration: sourceDuration), toDuration: clipDuration)
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
    static func buildVisuals(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize] = [:],
        clipTransforms: [String: CGAffineTransform] = [:],
        resolveTimeline: @Sendable (String) -> Timeline? = { _ in nil },
        compositionDuration: CMTime,
        renderSize: CGSize
    ) -> (audioMix: AVMutableAudioMix, videoComposition: AVVideoComposition) {
        let timescale = CMTimeScale(timeline.fps)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = trackMappings.filter { !$0.isVideo }.compactMap { mapping in
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
                for clip in clips {
                    emitVolumeEnvelope(params: params, clip: clip, timescale: timescale, carrier: liveCarrier)
                }
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
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    if let clipIds, !clipIds.contains(clip.id) { continue }
                    guard clip.durationFrames > 0, clip.startFrame >= prevEndFrame else { continue }
                    let strength = clip.hasDenoiseEnabled ? Float(min(1, max(0, clip.denoiseAmount))) : 0
                    let gain: Float = mapping.wetAudio
                        ? strength
                        : (mapping.blendedClipIds.contains(clip.id) ? 1 - strength : 1)
                    emitVolumeEnvelope(params: params, clip: clip, timescale: timescale, gain: gain)
                    prevEndFrame = clip.startFrame + clip.durationFrames
                }
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
    private static func emitVolumeEnvelope(
        params: AVMutableAudioMixInputParameters,
        clip: Clip,
        timescale: CMTimeScale,
        carrier: Clip? = nil,
        gain: Float = 1
    ) {
        let kfs = normalizedKeyframes(clip.volumeTrack?.keyframes ?? [], duration: clip.durationFrames)
        let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0
        let carrierVaries = carrier.map {
            ($0.volumeTrack?.isActive ?? false) || $0.fadeInFrames > 0 || $0.fadeOutFrames > 0
        } ?? false
        let gainAt: (Int) -> Double = { absFrame in
            carrier.map { $0.volumeAt(frame: absFrame) } ?? 1
        }
        if kfs.isEmpty && !hasFade && !carrierVaries {
            let volume = Float(clip.volumeAt(frame: clip.startFrame) * gainAt(clip.startFrame)) * gain
            let start = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
            let end = CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale)
            guard volume.isFinite, end > start else { return }
            params.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: start, end: end)
            )
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

        emitEnvelopeRamps(
            clip: clip,
            kfs: kfs,
            timescale: timescale,
            extraOffsets: extraOffsets,
            sampleAt: { Float(clip.volumeAt(frame: clip.startFrame + $0) * gainAt(clip.startFrame + $0)) * gain },
            emit: { start, end, range in
                params.setVolumeRamp(fromStartVolume: start, toEndVolume: end, timeRange: range)
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
        guard t.rotation != 0 else { return placed }
        let cx = t.centerX * renderSize.width
        let cy = t.centerY * renderSize.height
        return placed
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(rotationAngle: t.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
    }

}
