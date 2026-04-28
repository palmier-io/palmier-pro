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
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                let v = Float(clip.volume)
                let dur = clip.durationFrames
                let fIn = max(0, min(clip.audioFadeInFrames, dur))
                let fOut = max(0, min(clip.audioFadeOutFrames, dur - fIn))
                let startT = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                let endT = CMTime(value: CMTimeValue(clip.startFrame + dur), timescale: timescale)
                if fIn > 0 {
                    let kneeT = CMTime(value: CMTimeValue(clip.startFrame + fIn), timescale: timescale)
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: startT, end: kneeT))
                } else {
                    params.setVolume(v, at: startT)
                }
                if fOut > 0 {
                    let kneeT = CMTime(value: CMTimeValue(clip.startFrame + dur - fOut), timescale: timescale)
                    params.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: kneeT, end: endT))
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
                    let ct = clip.transform
                    let tl = ct.topLeft
                    let natSize = clipNaturalSizes[clip.id] ?? mapping.naturalSize

                    liConfig.setOpacity(Float(clip.opacity), at: start)
                    liConfig.setOpacity(0, at: end)
                    liConfig.setTransform(
                        CGAffineTransform(scaleX: (renderSize.width / natSize.width) * ct.width,
                                          y: (renderSize.height / natSize.height) * ct.height)
                            .concatenating(CGAffineTransform(translationX: tl.x * renderSize.width, y: tl.y * renderSize.height)),
                        at: start
                    )
                    let cp = clip.crop
                    liConfig.setCropRectangle(
                        CGRect(
                            x: cp.left * natSize.width,
                            y: cp.top * natSize.height,
                            width: max(1, cp.visibleWidthFraction * natSize.width),
                            height: max(1, cp.visibleHeightFraction * natSize.height)
                        ),
                        at: start
                    )
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
}
