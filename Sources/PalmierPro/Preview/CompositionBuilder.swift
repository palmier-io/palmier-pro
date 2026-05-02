import AVFoundation

struct TrackMapping: @unchecked Sendable {
    let compositionTrack: AVMutableCompositionTrack
    let timelineTrackIndex: Int
    let naturalSize: CGSize   // zero for audio-only mappings
    let endTime: CMTime       // .zero for audio-only mappings
    let isVideo: Bool
}

struct CompositionResult {
    let composition: AVMutableComposition
    let audioMix: AVMutableAudioMix
    let videoComposition: AVVideoComposition
    let trackMappings: [TrackMapping]
    let clipNaturalSizes: [String: CGSize]
}

/// Builds an AVFoundation composition from a Timeline.
enum CompositionBuilder {

    struct InvalidTimelineError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Invalid timeline: \(reason)" }
    }

    static func build(
        timeline: Timeline,
        resolveURL: @Sendable (String) -> URL?,
        resolveSourceSize: @Sendable (String) -> CGSize? = { _ in nil }
    ) async throws -> CompositionResult {
        Log.preview.info("build fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height) tracks=\(timeline.tracks.count)")
        guard timeline.fps > 0, timeline.width > 0, timeline.height > 0 else {
            Log.preview.fault("build: invalid timeline fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
            throw InvalidTimelineError(reason: "fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
        }
        let composition = AVMutableComposition()
        let timescale = CMTimeScale(timeline.fps)
        let renderSize = CGSize(width: timeline.width, height: timeline.height)
        var trackMappings: [TrackMapping] = []
        var clipNaturalSizes: [String: CGSize] = [:]

        for (trackIdx, track) in timeline.tracks.enumerated() {
            // Text renders via CATextLayer overlay (preview) + animation tool (export) — never as composition tracks.
            let sortedClips = track.clips
                .sorted { $0.startFrame < $1.startFrame }
                .filter { $0.mediaType != .text }
            guard !sortedClips.isEmpty else { continue }
            let isAudio = track.type == .audio
            let mediaType: AVMediaType = isAudio ? .audio : .video

            guard let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            if isAudio {
                trackMappings.append(TrackMapping(compositionTrack: compTrack, timelineTrackIndex: trackIdx, naturalSize: .zero, endTime: .zero, isVideo: false))
            }

            var cursor = CMTime.zero
            for clip in sortedClips {
                let mediaURL: URL
                guard let resolved = resolveURL(clip.mediaRef) else { continue }
                if clip.mediaType == .image {
                    let imageSize = resolveSourceSize(clip.mediaRef) ?? ImageVideoGenerator.imageNativeSize(url: resolved) ?? renderSize
                    do {
                        mediaURL = try await ImageVideoGenerator.stillVideo(
                            for: resolved, mediaRef: clip.mediaRef, size: imageSize
                        )
                    } catch {
                        Log.preview.error("stillVideo failed mediaRef=\(clip.mediaRef) size=\(Int(imageSize.width))x\(Int(imageSize.height)): \(error.localizedDescription)")
                        continue
                    }
                } else {
                    mediaURL = resolved
                }

                guard !Task.isCancelled else { throw CancellationError() }
                let sourceAsset = AVURLAsset(url: mediaURL)
                guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: mediaType).first else { continue }

                if !isAudio, let natSize = try? await sourceTrack.load(.naturalSize),
                   natSize.width > 0, natSize.height > 0 {
                    clipNaturalSizes[clip.id] = natSize
                }

                let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                let trimStartFrame = clip.mediaType == .image ? max(0, clip.trimStartFrame) : clip.trimStartFrame
                let trimStart = CMTime(value: CMTimeValue(trimStartFrame), timescale: timescale)
                let clipDuration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: timescale)

                if clipStart > cursor {
                    let gap = clipStart - cursor
                    compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                }

                let sourceDuration: CMTime
                if clip.speed != 1.0 {
                    sourceDuration = CMTime(value: Int64(Double(clip.durationFrames) * clip.speed), timescale: timescale)
                } else {
                    sourceDuration = clipDuration
                }
                let sourceRange = CMTimeRange(start: trimStart, duration: sourceDuration)

                do {
                    try compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: clipStart)
                } catch {
                    // Skip the bad clip rather than aborting the whole rebuild
                    let srcSeconds = (try? await sourceAsset.load(.duration).seconds) ?? 0
                    Log.preview.error("""
                        insertTimeRange failed — skipping clip. \
                        clipId=\(clip.id) mediaRef=\(clip.mediaRef) \
                        trimStart=\(clip.trimStartFrame)f durationFrames=\(clip.durationFrames)f \
                        speed=\(clip.speed) sourceSeconds=\(String(format: "%.3f", srcSeconds)) \
                        error=\(error.localizedDescription)
                        """)
                    continue
                }
                if clip.speed != 1.0 {
                    compTrack.scaleTimeRange(CMTimeRange(start: clipStart, duration: sourceDuration), toDuration: clipDuration)
                }

                cursor = clipStart + clipDuration
            }

            if !isAudio {
                let naturalSize = (try? await compTrack.load(.naturalSize)).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? renderSize
                trackMappings.append(TrackMapping(compositionTrack: compTrack, timelineTrackIndex: trackIdx, naturalSize: naturalSize, endTime: cursor, isVideo: true))
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        // Extend the composition so playback advances through text-only tails.
        let desiredDuration = CMTime(value: CMTimeValue(timeline.totalFrames), timescale: timescale)
        if !composition.tracks.isEmpty, desiredDuration > composition.duration {
            let gap = CMTimeRange(start: composition.duration, duration: desiredDuration - composition.duration)
            composition.insertEmptyTimeRange(gap)
        }

        let (audioMix, videoComposition) = buildVisuals(
            timeline: timeline,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes,
            compositionDuration: composition.duration
        )

        return CompositionResult(
            composition: composition,
            audioMix: audioMix,
            videoComposition: videoComposition,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes
        )
    }

    /// Rebuild only visual properties (transforms, opacity, volume)
    static func buildVisuals(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize] = [:],
        compositionDuration: CMTime
    ) -> (audioMix: AVMutableAudioMix, videoComposition: AVVideoComposition) {
        let timescale = CMTimeScale(timeline.fps)
        let renderSize = CGSize(width: timeline.width, height: timeline.height)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = trackMappings.filter { !$0.isVideo }.compactMap { mapping in
            guard timeline.tracks.indices.contains(mapping.timelineTrackIndex) else { return nil }
            let track = timeline.tracks[mapping.timelineTrackIndex]
            let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
            if track.muted {
                params.setVolume(0, at: .zero)
                return params
            }
            // AV ramps linearly between successive volume points; sub-ms ramp at boundaries forces a hard step.
            let stepRamp = CMTime(value: 1, timescale: 48_000)
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                let v = Float(clip.volume)
                let dur = clip.durationFrames
                let fIn = max(0, min(clip.audioFadeInFrames, dur))
                let fOut = max(0, min(clip.audioFadeOutFrames, dur - fIn))
                let startT = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                let endT = CMTime(value: CMTimeValue(clip.startFrame + dur), timescale: timescale)

                let entryDur: CMTime = fIn > 0
                    ? CMTime(value: CMTimeValue(fIn), timescale: timescale)
                    : stepRamp
                let exitDur: CMTime = fOut > 0
                    ? CMTime(value: CMTimeValue(fOut), timescale: timescale)
                    : stepRamp
                let entryEnd = min(startT + entryDur, endT)
                let exitStart = max(entryEnd, endT - exitDur)

                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: startT, end: entryEnd))
                if exitStart < endT {
                    params.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: exitStart, end: endT))
                }
            }
            return params
        }

        let layerInstructions: [AVVideoCompositionLayerInstruction] = trackMappings.filter { $0.isVideo }.map { mapping in
            var liConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: mapping.compositionTrack.trackID)
            let track = timeline.tracks.indices.contains(mapping.timelineTrackIndex)
                ? timeline.tracks[mapping.timelineTrackIndex] : nil

            liConfig.setOpacity(0, at: .zero)
            if let track, !track.hidden {
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    let start = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                    let end = CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale)
                    let natSize = clipNaturalSizes[clip.id] ?? mapping.naturalSize

                    emitOpacity(config: &liConfig, clip: clip, start: start, end: end, timescale: timescale)
                    liConfig.setOpacity(0, at: end)
                    emitTransform(config: &liConfig, clip: clip, start: start, end: end,
                                  natSize: natSize, renderSize: renderSize, timescale: timescale)
                    emitCrop(config: &liConfig, clip: clip, start: start, end: end,
                             natSize: natSize, timescale: timescale)
                }
            }
            if mapping.endTime < compositionDuration {
                liConfig.setOpacity(0, at: mapping.endTime)
            }
            return AVVideoCompositionLayerInstruction(configuration: liConfig)
        }

        var instrConfig = AVVideoCompositionInstruction.Configuration()
        instrConfig.timeRange = CMTimeRange(start: .zero, duration: compositionDuration)
        instrConfig.layerInstructions = layerInstructions
        let instruction = AVVideoCompositionInstruction(configuration: instrConfig)

        var vcConfig = AVVideoComposition.Configuration()
        vcConfig.renderSize = renderSize
        vcConfig.frameDuration = CMTime(value: 1, timescale: timescale)
        vcConfig.instructions = [instruction]

        return (audioMix, AVVideoComposition(configuration: vcConfig))
    }

    /// Smooth-curve subdivision count for non-linear keyframe segments.
    private static let smoothSegments = 8

    /// Emit the transform instructions from a clip's keyframes
    private static func emitTransform(
        config: inout AVVideoCompositionLayerInstruction.Configuration,
        clip: Clip,
        start: CMTime,
        end: CMTime,
        natSize: CGSize,
        renderSize: CGSize,
        timescale: CMTimeScale
    ) {
        let affine: (Transform) -> CGAffineTransform = { t in
            let tl = t.topLeft
            return CGAffineTransform(
                scaleX: (renderSize.width / natSize.width) * t.width,
                y: (renderSize.height / natSize.height) * t.height
            ).concatenating(CGAffineTransform(translationX: tl.x * renderSize.width, y: tl.y * renderSize.height))
        }

        guard clip.hasTransformAnimation else {
            config.setTransform(affine(clip.transform), at: start)
            return
        }

        // Union of position + scale offsets, defensively clamped to [0, durationFrames].
        var offsetSet = Set<Int>()
        for kf in clip.positionTrack?.keyframes ?? [] where kf.frame >= 0 && kf.frame <= clip.durationFrames {
            offsetSet.insert(kf.frame)
        }
        for kf in clip.scaleTrack?.keyframes ?? [] where kf.frame >= 0 && kf.frame <= clip.durationFrames {
            offsetSet.insert(kf.frame)
        }
        let offsets = offsetSet.sorted()

        guard let firstOffset = offsets.first else {
            config.setTransform(affine(clip.transform), at: start)
            return
        }

        // Track storage uses clip-relative offsets; we shift to absolute by adding `clip.startFrame`
        let cmTime: (Int) -> CMTime = { offset in
            CMTime(value: CMTimeValue(clip.startFrame + offset), timescale: timescale)
        }

        // Hold the first kf's value before it
        config.setTransform(affine(clip.transformAt(frame: clip.startFrame + firstOffset)), at: start)

        // Subdivide each segment using fractional CMTimes so consecutive ramps never
        // share a timeRange (integer-frame rounding would collapse short spans).
        for i in 0..<(offsets.count - 1) {
            let aOff = offsets[i], bOff = offsets[i + 1]
            let aT = cmTime(aOff)
            let bT = cmTime(bOff)
            let span = bT - aT
            guard span > .zero else { continue }
            var prevT = aT
            var prevTransform = clip.transformAt(frame: clip.startFrame + aOff)
            for s in 1...smoothSegments {
                let t = Double(s) / Double(smoothSegments)
                let nextT = aT + CMTime(seconds: span.seconds * t, preferredTimescale: span.timescale)
                let offsetAtT = aOff + Int((Double(bOff - aOff) * t).rounded())
                let nextTransform = clip.transformAt(frame: clip.startFrame + offsetAtT)
                if nextT > prevT {
                    config.addTransformRamp(.init(
                        timeRange: CMTimeRange(start: prevT, end: nextT),
                        start: affine(prevTransform),
                        end: affine(nextTransform)
                    ))
                }
                prevT = nextT
                prevTransform = nextTransform
            }
        }

        // Hold last value until the clip's end.
        let lastOffset = offsets.last!
        let lastT = cmTime(lastOffset)
        if lastT < end {
            config.setTransform(affine(clip.transformAt(frame: clip.startFrame + lastOffset)), at: lastT)
        }
    }

    /// Emit the crop instructions from a clip's keyframes
    private static func emitCrop(
        config: inout AVVideoCompositionLayerInstruction.Configuration,
        clip: Clip,
        start: CMTime,
        end: CMTime,
        natSize: CGSize,
        timescale: CMTimeScale
    ) {
        let rect: (Crop) -> CGRect = { cp in
            CGRect(
                x: cp.left * natSize.width,
                y: cp.top * natSize.height,
                width: max(1, cp.visibleWidthFraction * natSize.width),
                height: max(1, cp.visibleHeightFraction * natSize.height)
            )
        }
        let ops = trackOps(track: clip.cropTrack, fallback: clip.crop, clip: clip,
                           clipStart: start, clipEnd: end, timescale: timescale)
        for op in ops {
            switch op {
            case .setStatic(let v, let t):
                config.setCropRectangle(rect(v), at: t)
            case .ramp(let a, let b, let range):
                config.addCropRectangleRamp(.init(timeRange: range, start: rect(a), end: rect(b)))
            }
        }
    }

    /// Emit the opacity instructions from a clip's keyframes
    private static func emitOpacity(
        config: inout AVVideoCompositionLayerInstruction.Configuration,
        clip: Clip,
        start: CMTime,
        end: CMTime,
        timescale: CMTimeScale
    ) {
        let ops = trackOps(track: clip.opacityTrack, fallback: clip.opacity, clip: clip,
                           clipStart: start, clipEnd: end, timescale: timescale)
        for op in ops {
            switch op {
            case .setStatic(let v, let t):
                config.setOpacity(Float(v), at: t)
            case .ramp(let a, let b, let range):
                config.addOpacityRamp(.init(timeRange: range, start: Float(a), end: Float(b)))
            }
        }
    }

    /// One emitted ramp instruction. Generated by `trackOps` and consumed per-property by
    /// the appropriate AVFoundation API (`setOpacity` / `setCropRectangle` / etc.).
    private enum TrackOp<V> {
        case setStatic(V, CMTime)
        case ramp(V, V, CMTimeRange)
    }

    /// Compute the ramp instructions for a single-property keyframe track
    private static func trackOps<V: KeyframeInterpolatable & Codable & Sendable & Equatable>(
        track: KeyframeTrack<V>?,
        fallback: V,
        clip: Clip,
        clipStart: CMTime,
        clipEnd: CMTime,
        timescale: CMTimeScale
    ) -> [TrackOp<V>] {
        guard let track, track.isActive else {
            return [.setStatic(fallback, clipStart)]
        }
        // Defensive: drop kfs whose offsets fall outside the clip's visible range.
        let kfs = track.keyframes.filter { $0.frame >= 0 && $0.frame <= clip.durationFrames }
        guard !kfs.isEmpty else {
            return [.setStatic(fallback, clipStart)]
        }

        // Track storage uses clip-relative offsets; we shift to absolute by adding `clip.startFrame`
        let cmTime: (Int) -> CMTime = { offset in
            CMTime(value: CMTimeValue(clip.startFrame + offset), timescale: timescale)
        }

        var ops: [TrackOp<V>] = []
        let firstT = cmTime(kfs[0].frame)
        if firstT > clipStart {
            ops.append(.setStatic(kfs[0].value, clipStart))
        }
        for i in 0..<(kfs.count - 1) {
            let a = kfs[i], b = kfs[i + 1]
            let aT = cmTime(a.frame)
            let bT = cmTime(b.frame)
            switch a.interpolationOut {
            case .hold:
                ops.append(.setStatic(a.value, aT))
            case .linear:
                ops.append(.ramp(a.value, b.value, CMTimeRange(start: aT, end: bT)))
            case .smooth:
                let span = bT - aT
                guard span > .zero else { continue }
                var prevT = aT
                var prevValue = a.value
                for s in 1...smoothSegments {
                    let t = Double(s) / Double(smoothSegments)
                    let nextValue = V.keyframeInterpolate(a.value, b.value, t: smoothstep(t))
                    let nextT = aT + CMTime(seconds: span.seconds * t, preferredTimescale: span.timescale)
                    if nextT > prevT {
                        ops.append(.ramp(prevValue, nextValue, CMTimeRange(start: prevT, end: nextT)))
                    }
                    prevT = nextT
                    prevValue = nextValue
                }
            }
        }
        let last = kfs.last!
        let lastT = cmTime(last.frame)
        if lastT < clipEnd {
            ops.append(.setStatic(last.value, lastT))
        }
        return ops
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
