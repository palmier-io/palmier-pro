import AVFoundation

struct TrackMapping: @unchecked Sendable {
    enum Kind {
        case timeline(trackIndex: Int)
        case blackTail(range: CMTimeRange)
    }
    let compositionTrack: AVMutableCompositionTrack
    let kind: Kind
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
        resolveSourceSize: @Sendable (String) -> CGSize? = { _ in nil },
        renderSize: CGSize
    ) async throws -> CompositionResult {
        Log.preview.info("build fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height) tracks=\(timeline.tracks.count)")
        guard timeline.fps > 0, timeline.width > 0, timeline.height > 0 else {
            Log.preview.fault("build: invalid timeline fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
            throw InvalidTimelineError(reason: "fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
        }
        let composition = AVMutableComposition()
        let timescale = CMTimeScale(timeline.fps)
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
                trackMappings.append(TrackMapping(compositionTrack: compTrack, kind: .timeline(trackIndex: trackIdx), naturalSize: .zero, endTime: .zero, isVideo: false))
            }

            var cursor = CMTime.zero
            var insertedCount = 0
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
                let sourceTrack: AVAssetTrack
                do {
                    guard let track = try await sourceAsset.loadTracks(withMediaType: mediaType).first else { continue }
                    sourceTrack = track
                } catch {
                    Log.preview.error("loadTracks failed — skipping clip. clipId=\(clip.id) mediaRef=\(clip.mediaRef): \(error.localizedDescription)")
                    continue
                }

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
                insertedCount += 1
            }

            if !isAudio {
                guard insertedCount > 0 else {
                    composition.removeTrack(compTrack)
                    continue
                }
                let naturalSize = (try? await compTrack.load(.naturalSize)).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? renderSize
                trackMappings.append(TrackMapping(compositionTrack: compTrack, kind: .timeline(trackIndex: trackIdx), naturalSize: naturalSize, endTime: cursor, isVideo: true))
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        // Pad video coverage to the full timeline so text-only tails actually render
        let desiredDuration = CMTime(value: CMTimeValue(timeline.totalFrames), timescale: timescale)
        let lastVideoEnd = trackMappings.filter(\.isVideo).map(\.endTime).max() ?? .zero
        if desiredDuration > lastVideoEnd {
            let tailRange = CMTimeRange(start: lastVideoEnd, duration: desiredDuration - lastVideoEnd)
            if let mapping = try await insertBlackTail(
                composition: composition,
                size: renderSize,
                range: tailRange
            ) {
                trackMappings.append(mapping)
            }
        }

        let (audioMix, videoComposition) = buildVisuals(
            timeline: timeline,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes,
            compositionDuration: composition.duration,
            renderSize: renderSize
        )

        return CompositionResult(
            composition: composition,
            audioMix: audioMix,
            videoComposition: videoComposition,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes
        )
    }

    private static func insertBlackTail(
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
            kind: .blackTail(range: range),
            naturalSize: size,
            endTime: range.end,
            isVideo: true
        )
    }

    /// Rebuild only visual properties (transforms, opacity, volume)
    static func buildVisuals(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize] = [:],
        compositionDuration: CMTime,
        renderSize: CGSize
    ) -> (audioMix: AVMutableAudioMix, videoComposition: AVVideoComposition) {
        let timescale = CMTimeScale(timeline.fps)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = trackMappings.filter { !$0.isVideo }.compactMap { mapping in
            guard case .timeline(let trackIndex) = mapping.kind,
                  timeline.tracks.indices.contains(trackIndex) else { return nil }
            let track = timeline.tracks[trackIndex]
            let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
            if track.muted {
                params.setVolume(0, at: .zero)
                return params
            }
            var prevEndFrame = Int.min
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                guard clip.durationFrames > 0, clip.startFrame >= prevEndFrame else { continue }
                emitVolumeEnvelope(params: params, clip: clip, timescale: timescale)
                prevEndFrame = clip.startFrame + clip.durationFrames
            }
            return params
        }

        let layerInstructions: [AVVideoCompositionLayerInstruction] = trackMappings.filter { $0.isVideo }.map { mapping in
            var liConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: mapping.compositionTrack.trackID)
            liConfig.setOpacity(0, at: .zero)

            switch mapping.kind {
            case .blackTail(let range):
                liConfig.setOpacity(1, at: range.start)
                if range.end < compositionDuration {
                    liConfig.setOpacity(0, at: range.end)
                }
                return AVVideoCompositionLayerInstruction(configuration: liConfig)
            case .timeline(let trackIndex):
                let track = timeline.tracks.indices.contains(trackIndex)
                    ? timeline.tracks[trackIndex] : nil
                if let track, !track.hidden {
                    for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame })
                        where clip.mediaType != .text {
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
        }

        var instrConfig = AVVideoCompositionInstruction.Configuration()
        instrConfig.timeRange = CMTimeRange(start: .zero, duration: compositionDuration)
        instrConfig.layerInstructions = layerInstructions
        let instruction = AVVideoCompositionInstruction(configuration: instrConfig)

        var vcConfig = AVVideoComposition.Configuration()
        vcConfig.renderSize = renderSize
        vcConfig.frameDuration = CMTime(value: 1, timescale: timescale)
        vcConfig.instructions = [instruction]
        vcConfig.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vcConfig.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vcConfig.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        return (audioMix, AVVideoComposition(configuration: vcConfig))
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

    /// Linear-ramp envelope for the clip's volume curve. `volumeAt` already folds in static × kf × fade.
    private static func emitVolumeEnvelope(
        params: AVMutableAudioMixInputParameters,
        clip: Clip,
        timescale: CMTimeScale
    ) {
        let kfs = (clip.volumeTrack?.keyframes ?? []).filter { $0.frame >= 0 && $0.frame <= clip.durationFrames }
        let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0
        if kfs.isEmpty && !hasFade && Float(clip.volume) == 1.0 { return }

        emitEnvelopeRamps(
            clip: clip,
            kfs: kfs,
            timescale: timescale,
            sampleAt: { Float(clip.volumeAt(frame: clip.startFrame + $0)) },
            emit: { start, end, range in
                params.setVolumeRamp(fromStartVolume: start, toEndVolume: end, timeRange: range)
            }
        )
    }

    /// Piecewise-linear envelope shared by audio volume and video opacity fade emission.
    private static func emitEnvelopeRamps(
        clip: Clip,
        kfs: [Keyframe<Double>],
        timescale: CMTimeScale,
        sampleAt: (Int) -> Float,
        emit: (Float, Float, CMTimeRange) -> Void
    ) {
        let dur = clip.durationFrames
        guard dur > 0 else { return }

        var offsetSet: Set<Int> = [0, dur]
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
            affineTransform(for: t, natSize: natSize, renderSize: renderSize)
        }

        guard clip.hasTransformAnimation else {
            config.setTransform(affine(clip.transform), at: start)
            return
        }

        // Union of position + scale + rotation offsets, defensively clamped to [0, durationFrames].
        var offsetSet = Set<Int>()
        for kf in clip.positionTrack?.keyframes ?? [] where kf.frame >= 0 && kf.frame <= clip.durationFrames {
            offsetSet.insert(kf.frame)
        }
        for kf in clip.scaleTrack?.keyframes ?? [] where kf.frame >= 0 && kf.frame <= clip.durationFrames {
            offsetSet.insert(kf.frame)
        }
        for kf in clip.rotationTrack?.keyframes ?? [] where kf.frame >= 0 && kf.frame <= clip.durationFrames {
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

        // Hold the first kf's value during the [start, firstKf) gap.
        if firstOffset > 0 {
            config.setTransform(affine(clip.transformAt(frame: clip.startFrame + firstOffset)), at: start)
        }

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
                let nextT = aT + CMTime(seconds: span.seconds * t, preferredTimescale: span.timescale * Int32(smoothSegments))
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

    /// Opacity instructions for a clip's keyframes + fade envelope.
    private static func emitOpacity(
        config: inout AVVideoCompositionLayerInstruction.Configuration,
        clip: Clip,
        start: CMTime,
        end: CMTime,
        timescale: CMTimeScale
    ) {
        let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0

        if !hasFade {
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
            return
        }

        let kfs = (clip.opacityTrack?.isActive == true)
            ? (clip.opacityTrack?.keyframes ?? []).filter { $0.frame >= 0 && $0.frame <= clip.durationFrames }
            : []

        config.setOpacity(Float(clip.opacityAt(frame: clip.startFrame)), at: start)
        emitEnvelopeRamps(
            clip: clip,
            kfs: kfs,
            timescale: timescale,
            sampleAt: { Float(clip.opacityAt(frame: clip.startFrame + $0)) },
            emit: { aVal, bVal, range in
                config.addOpacityRamp(.init(timeRange: range, start: aVal, end: bVal))
            }
        )
    }

    /// One emitted ramp instruction. Generated by `trackOps` and consumed per-property by
    /// the appropriate AVFoundation API (`setOpacity` / `setCropRectangle` / etc.).
    enum TrackOp<V> {
        case setStatic(V, CMTime)
        case ramp(V, V, CMTimeRange)
    }

    /// Compute the ramp instructions for a single-property keyframe track
    static func trackOps<V: KeyframeInterpolatable & Codable & Sendable & Equatable>(
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
                    let nextT = aT + CMTime(seconds: span.seconds * t, preferredTimescale: span.timescale * Int32(smoothSegments))
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
}
