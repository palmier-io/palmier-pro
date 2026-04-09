import AVFoundation
import AppKit

@Observable
@MainActor
final class VideoEngine {
    private(set) var player = AVPlayer()
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?

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
        guard let editor else { return }
        editor.isPlaying = true
        guard rebuildTask == nil else { return }
        let frame = editor.activePreviewTab == .timeline ? editor.currentFrame : editor.sourcePlayheadFrame
        seek(to: frame)
        player.play()
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

    func activateTab(_ tab: PreviewTab) {
        guard let editor else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        pause()
        switch tab {
        case .timeline:
            rebuild()
        case .mediaAsset(let id, _, let type):
            guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return }
            if type == .image {
                player.replaceCurrentItem(with: nil)
            } else {
                previewAsset(asset)
                seek(to: editor.sourcePlayheadFrame)
            }
        }
    }

    func rebuild() {
        guard let editor, editor.activePreviewTab == .timeline else { return }
        rebuildTask?.cancel()
        rebuildTask = Task {
            let item = await buildPlayerItem()
            rebuildTask = nil
            guard !Task.isCancelled else { return }
            player.replaceCurrentItem(with: item)
            seek(to: editor.currentFrame)
            if editor.isPlaying {
                player.play()
            }
        }
    }

    /// Builds an AVPlayerItem from the current timeline.
    private func buildPlayerItem() async -> AVPlayerItem? {
        guard let editor else { return nil }
        let timeline = editor.timeline
        guard !timeline.tracks.isEmpty else { return nil }

        let composition = AVMutableComposition()
        let timescale = CMTimeScale(timeline.fps)
        let renderSize = CGSize(width: timeline.width, height: timeline.height)

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

                guard !Task.isCancelled else { return nil }
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

        guard !Task.isCancelled else { return nil }

        // Audio mix
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixEntries.map { entry in
            let params = AVMutableAudioMixInputParameters(track: entry.track)
            params.setVolume(entry.muted ? 0 : 1, at: .zero)
            return params
        }

        // Video composition: layering, visibility, scaling
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        for entry in videoLayerEntries {
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
            if entry.hidden { li.setOpacity(0, at: .zero) }
            if entry.endTime < composition.duration { li.setOpacity(0, at: entry.endTime) }
            if let size = try? await entry.track.load(.naturalSize), size.width > 0, size.height > 0 {
                li.setTransform(CGAffineTransform(
                    scaleX: renderSize.width / size.width,
                    y: renderSize.height / size.height
                ), at: .zero)
            }
            layerInstructions.append(li)
        }
        instruction.layerInstructions = layerInstructions
        videoComposition.instructions = [instruction]

        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.videoComposition = videoComposition
        return item
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
