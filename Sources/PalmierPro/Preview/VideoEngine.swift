import AVFoundation
import AppKit

@Observable
@MainActor
final class VideoEngine {
    private(set) var player = AVPlayer()
    private var timeObserver: Any?
    private var compositionNeedsRebuild = true
    private var isRebuilding = false
    private var activationTask: Task<Void, Never>?

    weak var editor: EditorViewModel?

    init(editor: EditorViewModel) {
        self.editor = editor
        setupTimeObserver()
    }

    /// Must be called before discarding this engine (e.g. window close).
    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: - Playback control

    func play() {
        guard let editor, !isRebuilding else { return }
        if editor.activePreviewTab == .timeline && compositionNeedsRebuild {
            isRebuilding = true
            Task {
                await rebuildComposition()
                let time = CMTime(value: CMTimeValue(editor.currentFrame), timescale: CMTimeScale(editor.timeline.fps))
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                isRebuilding = false
                player.play()
                editor.isPlaying = true
            }
        } else {
            let frame = editor.activePreviewTab == .timeline ? editor.currentFrame : editor.sourcePlayheadFrame
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(editor.timeline.fps))
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            editor.isPlaying = true
        }
    }

    func pause() {
        player.pause()
        editor?.isPlaying = false
    }

    func togglePlayback() {
        if editor?.isPlaying == true { pause() } else { play() }
    }

    func seek(to frame: Int) {
        guard let editor else { return }
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(editor.timeline.fps))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Preview modes

    func previewAsset(_ asset: MediaAsset) {
        let item = AVPlayerItem(url: asset.url)
        player.replaceCurrentItem(with: item)
        compositionNeedsRebuild = true
    }

    func activateTab(_ tab: PreviewTab) {
        guard let editor else { return }
        activationTask?.cancel()
        pause()
        switch tab {
        case .timeline:
            if compositionNeedsRebuild {
                activationTask = Task {
                    await rebuildComposition()
                    guard !Task.isCancelled else { return }
                    seek(to: editor.currentFrame)
                }
            } else {
                seek(to: editor.currentFrame)
            }
        case .mediaAsset(let id, _, let type):
            guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return }
            if type == .image {
                player.replaceCurrentItem(with: nil)
                compositionNeedsRebuild = true
            } else {
                previewAsset(asset)
                seek(to: editor.sourcePlayheadFrame)
            }
        }
    }

    /// Build composition from timeline for multi-clip playback.
    /// Video tracks are layered bottom-to-top (last track = background, first = foreground).
    /// Respects track.muted (silences audio) and track.hidden (hides video).
    func rebuildComposition() async {
        guard let editor else { return }
        let timeline = editor.timeline
        guard !timeline.tracks.isEmpty else {
            player.replaceCurrentItem(with: nil)
            return
        }

        let composition = AVMutableComposition()
        let fps = timeline.fps
        let timescale = CMTimeScale(fps)
        let renderSize = CGSize(width: timeline.width, height: timeline.height)

        // Collect per-track info for video layering and audio mixing
        var videoLayerEntries: [(track: AVMutableCompositionTrack, hidden: Bool, endTime: CMTime)] = []
        var audioMixEntries: [(track: AVMutableCompositionTrack, muted: Bool)] = []

        for track in timeline.tracks {
            let sortedClips = track.clips.sorted { $0.startFrame < $1.startFrame }
            guard !sortedClips.isEmpty else { continue }
            let isAudio = track.type == .audio
            let mediaType: AVMediaType = isAudio ? .audio : .video

            guard let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            let audioCompTrack: AVMutableCompositionTrack?
            if isAudio {
                audioCompTrack = nil
                audioMixEntries.append((compTrack, track.muted))
            } else {
                audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                if let audioCompTrack {
                    audioMixEntries.append((audioCompTrack, track.muted))
                }
            }

            var cursor = CMTime.zero
            for clip in sortedClips {
                guard var mediaURL = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                if clip.mediaType == .image {
                    guard let videoURL = try? await ImageVideoGenerator.stillVideo(
                        for: mediaURL, mediaRef: clip.mediaRef, size: renderSize
                    ) else { continue }
                    mediaURL = videoURL
                }

                let sourceAsset = AVURLAsset(url: mediaURL)
                guard let sourceTrack = try? await sourceAsset.loadTracks(withMediaType: mediaType).first else { continue }

                let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
                let trimStart = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: timescale)
                let duration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: timescale)
                let sourceRange = CMTimeRange(start: trimStart, duration: duration)

                if clipStart > cursor {
                    let gap = clipStart - cursor
                    compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                    audioCompTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                }

                try? compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: clipStart)

                if let audioCompTrack,
                   let audioSource = try? await sourceAsset.loadTracks(withMediaType: .audio).first {
                    try? audioCompTrack.insertTimeRange(sourceRange, of: audioSource, at: clipStart)
                }

                cursor = clipStart + duration
            }

            if !isAudio {
                videoLayerEntries.append((compTrack, track.hidden, cursor))
            }
        }

        // --- Audio mix: apply mute via volume ---
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixEntries.map { entry in
            let params = AVMutableAudioMixInputParameters(track: entry.track)
            params.setVolume(entry.muted ? 0 : 1, at: .zero)
            return params
        }

        // --- Video composition: layer tracks with opacity ---
        let totalDuration = composition.duration
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        // Build a single instruction spanning the entire composition
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)

        // Layer video tracks: track 0 (top in timeline) = foreground (first in array = topmost)
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        for entry in videoLayerEntries {
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
            if entry.hidden {
                layerInstruction.setOpacity(0, at: .zero)
            }
            if entry.endTime < totalDuration {
                layerInstruction.setOpacity(0, at: entry.endTime)
            }
            // Scale source video to fill render size
            if let naturalSize = try? await entry.track.load(.naturalSize),
               naturalSize.width > 0, naturalSize.height > 0 {
                let scaleX = renderSize.width / naturalSize.width
                let scaleY = renderSize.height / naturalSize.height
                let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
                layerInstruction.setTransform(transform, at: .zero)
            }
            layerInstructions.append(layerInstruction)
        }
        instruction.layerInstructions = layerInstructions
        videoComposition.instructions = [instruction]

        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.videoComposition = videoComposition
        player.replaceCurrentItem(with: item)
        compositionNeedsRebuild = false
    }

    func markNeedsRebuild() {
        compositionNeedsRebuild = true
    }

    // MARK: - Private

    private func setupTimeObserver() {
        guard let editor else { return }
        let fps = editor.timeline.fps
        let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard let editor = self.editor else { return }
                if editor.isPlaying && !editor.isScrubbing {
                    let frame = secondsToFrame(seconds: time.seconds, fps: editor.timeline.fps)
                    if editor.activePreviewTab == .timeline {
                        editor.currentFrame = frame
                    } else {
                        editor.sourcePlayheadFrame = frame
                    }
                }
            }
        }
    }
}
