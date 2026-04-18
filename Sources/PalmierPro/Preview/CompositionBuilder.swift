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

    static func build(
        timeline: Timeline,
        resolveURL: @Sendable (String) -> URL?,
        resolveSourceSize: @Sendable (String) -> CGSize? = { _ in nil }
    ) async throws -> CompositionResult {
        Log.preview.info("build fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height) tracks=\(timeline.tracks.count)")
        if timeline.fps <= 0 || timeline.width <= 0 || timeline.height <= 0 {
            Log.preview.fault("build: invalid timeline settings — CMTimeScale/render will corrupt")
        }
        let composition = AVMutableComposition()
        let timescale = CMTimeScale(timeline.fps)
        let renderSize = CGSize(width: timeline.width, height: timeline.height)
        var trackMappings: [TrackMapping] = []
        var clipNaturalSizes: [String: CGSize] = [:]

        for (trackIdx, track) in timeline.tracks.enumerated() {
            let sortedClips = track.clips.sorted { $0.startFrame < $1.startFrame }
            guard !sortedClips.isEmpty else { continue }
            let isAudio = track.type == .audio
            let mediaType: AVMediaType = isAudio ? .audio : .video

            guard let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            if isAudio {
                trackMappings.append(TrackMapping(compositionTrack: compTrack, timelineTrackIndex: trackIdx, naturalSize: .zero, endTime: .zero, isVideo: false))
            }

            var cursor = CMTime.zero
            for clip in sortedClips {
                guard var mediaURL = resolveURL(clip.mediaRef) else { continue }
                if clip.mediaType == .image {
                    let imageSize = resolveSourceSize(clip.mediaRef) ?? ImageVideoGenerator.imageNativeSize(url: mediaURL) ?? renderSize
                    guard let videoURL = try? await ImageVideoGenerator.stillVideo(
                        for: mediaURL, mediaRef: clip.mediaRef, size: imageSize
                    ) else { continue }
                    mediaURL = videoURL
                }

                guard !Task.isCancelled else { throw CancellationError() }
                let sourceAsset = AVURLAsset(url: mediaURL)
                guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: mediaType).first else { continue }

                if !isAudio, let natSize = try? await sourceTrack.load(.naturalSize),
                   natSize.width > 0, natSize.height > 0 {
                    clipNaturalSizes[clip.id] = natSize
                }

                let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                let trimStart = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: timescale)
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

                try compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: clipStart)
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
            params.setVolume(0, at: .zero)
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                let vol: Float = track.muted ? 0 : Float(clip.volume)
                params.setVolume(vol, at: CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale))
                params.setVolume(0, at: CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale))
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
