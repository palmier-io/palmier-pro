import AVFoundation
import AppKit

@Observable
@MainActor
final class VideoEngine {
    private(set) var player = AVPlayer()
    private var timeObserver: Any?
    private var compositionNeedsRebuild = true
    private var isRebuilding = false

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
        if compositionNeedsRebuild {
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
            let time = CMTime(value: CMTimeValue(editor.currentFrame), timescale: CMTimeScale(editor.timeline.fps))
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
        var videoLayerEntries: [(track: AVMutableCompositionTrack, hidden: Bool)] = []
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
                guard let mediaURL = resolveMediaURL(clip.mediaRef) else { continue }
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
                videoLayerEntries.append((compTrack, track.hidden))
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

        // Layer video tracks: last timeline track = bottom layer (rendered first, behind others)
        // Reversed so that track 0 (top in timeline) is the foreground
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        for entry in videoLayerEntries.reversed() {
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
            if entry.hidden {
                layerInstruction.setOpacity(0, at: .zero)
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
                    editor.currentFrame = secondsToFrame(seconds: time.seconds, fps: editor.timeline.fps)
                }
            }
        }
    }

    private func resolveMediaURL(_ mediaRef: String) -> URL? {
        editor?.mediaAssets.first { $0.url.lastPathComponent == mediaRef }?.url
    }
}
