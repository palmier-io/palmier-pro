import AVFoundation

struct CompositionResult {
    let composition: AVMutableComposition
    let audioMix: AVMutableAudioMix
    let videoComposition: AVMutableVideoComposition
}

/// Builds an AVFoundation composition from a Timeline.
enum CompositionBuilder {

    static func build(
        timeline: Timeline,
        resolveURL: @Sendable (String) -> URL?
    ) async throws -> CompositionResult {
        let composition = AVMutableComposition()
        let timescale = CMTimeScale(timeline.fps)
        let renderSize = CGSize(width: timeline.width, height: timeline.height)

        var videoEntries: [(track: AVMutableCompositionTrack, hidden: Bool, clips: [Clip], endTime: CMTime)] = []
        var audioEntries: [(track: AVMutableCompositionTrack, muted: Bool, clips: [Clip])] = []

        for track in timeline.tracks {
            let sortedClips = track.clips.sorted { $0.startFrame < $1.startFrame }
            guard !sortedClips.isEmpty else { continue }
            let isAudio = track.type == .audio
            let mediaType: AVMediaType = isAudio ? .audio : .video

            guard let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let audioCompTrack: AVMutableCompositionTrack? = isAudio ? nil :
                composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

            if isAudio {
                audioEntries.append((compTrack, track.muted, sortedClips))
            } else if let audioCompTrack {
                audioEntries.append((audioCompTrack, track.muted, sortedClips))
            }

            var cursor = CMTime.zero
            for clip in sortedClips {
                guard var mediaURL = resolveURL(clip.mediaRef) else { continue }
                if clip.mediaType == .image {
                    guard let videoURL = try? await ImageVideoGenerator.stillVideo(
                        for: mediaURL, mediaRef: clip.mediaRef, size: renderSize
                    ) else { continue }
                    mediaURL = videoURL
                }

                guard !Task.isCancelled else { throw CancellationError() }
                let sourceAsset = AVURLAsset(url: mediaURL)
                guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: mediaType).first else { continue }

                let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                let trimStart = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: timescale)
                let clipDuration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: timescale)

                if clipStart > cursor {
                    let gap = clipStart - cursor
                    compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                    audioCompTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
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

                if let audioCompTrack, let audioSource = try? await sourceAsset.loadTracks(withMediaType: .audio).first {
                    try? audioCompTrack.insertTimeRange(sourceRange, of: audioSource, at: clipStart)
                    if clip.speed != 1.0 {
                        audioCompTrack.scaleTimeRange(CMTimeRange(start: clipStart, duration: sourceDuration), toDuration: clipDuration)
                    }
                }

                cursor = clipStart + clipDuration
            }

            if !isAudio {
                videoEntries.append((compTrack, track.hidden, sortedClips, cursor))
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioEntries.map { entry in
            let params = AVMutableAudioMixInputParameters(track: entry.track)
            params.setVolume(0, at: .zero)
            for clip in entry.clips {
                let vol: Float = entry.muted ? 0 : Float(clip.volume)
                params.setVolume(vol, at: CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale))
                params.setVolume(0, at: CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale))
            }
            return params
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        instruction.layerInstructions = await videoEntries.asyncMap { entry in
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
            let naturalSize = (try? await entry.track.load(.naturalSize)).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? renderSize

            li.setOpacity(0, at: .zero)
            if !entry.hidden {
                for clip in entry.clips {
                    let start = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                    let end = CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale)
                    let ct = clip.transform

                    li.setOpacity(Float(clip.opacity), at: start)
                    li.setOpacity(0, at: end)

                    let tl = ct.topLeft
                    let sx = (renderSize.width / naturalSize.width) * ct.width
                    let sy = (renderSize.height / naturalSize.height) * ct.height
                    let tx = tl.x * renderSize.width
                    let ty = tl.y * renderSize.height
                    li.setTransform(
                        CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: tx, y: ty)),
                        at: start
                    )
                }
            }
            if entry.endTime < composition.duration {
                li.setOpacity(0, at: entry.endTime)
            }
            return li
        }

        videoComposition.instructions = [instruction]
        return CompositionResult(composition: composition, audioMix: audioMix, videoComposition: videoComposition)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            try results.append(await transform(element))
        }
        return results
    }
}
