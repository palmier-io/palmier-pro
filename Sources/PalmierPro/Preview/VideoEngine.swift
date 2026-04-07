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
            // No rebuild needed — just seek and play
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

    /// Build composition from timeline for multi-clip playback
    func rebuildComposition() async {
        guard let editor else { return }
        let timeline = editor.timeline
        guard !timeline.tracks.isEmpty else {
            player.replaceCurrentItem(with: nil)
            return
        }

        let composition = AVMutableComposition()
        let fps = timeline.fps

        for track in timeline.tracks {
            let sortedClips = track.clips.sorted { $0.startFrame < $1.startFrame }
            guard !sortedClips.isEmpty else { continue }
            let isAudio = track.type == .audio
            let mediaType: AVMediaType = isAudio ? .audio : .video

            guard let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            let audioCompTrack: AVMutableCompositionTrack? = isAudio ? nil :
                composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

            var cursor = CMTime.zero
            for clip in sortedClips {
                guard let mediaURL = resolveMediaURL(clip.mediaRef) else { continue }
                let sourceAsset = AVURLAsset(url: mediaURL)
                guard let sourceTrack = try? await sourceAsset.loadTracks(withMediaType: mediaType).first else { continue }

                let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: CMTimeScale(fps))
                let trimStart = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(fps))
                let duration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: CMTimeScale(fps))
                let sourceRange = CMTimeRange(start: trimStart, duration: duration)

                if clipStart > cursor {
                    let gap = clipStart - cursor
                    compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                    audioCompTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                }

                try? compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: clipStart)

                if let audioCompTrack, let audioSource = try? await sourceAsset.loadTracks(withMediaType: .audio).first {
                    try? audioCompTrack.insertTimeRange(sourceRange, of: audioSource, at: clipStart)
                }

                cursor = clipStart + duration
            }
        }

        let item = AVPlayerItem(asset: composition)
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
