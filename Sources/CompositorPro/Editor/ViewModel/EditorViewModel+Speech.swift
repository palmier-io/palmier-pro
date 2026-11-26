import Foundation

extension EditorViewModel {
    func prepareSpeechPlacement(_ asset: MediaAsset, at frame: Int?) throws -> ClipPlacement.Clips? {
        guard let frame else { return nil }
        return try ClipPlacement.make(source: .init(asset: asset), trackType: .audio,
            fps: timeline.fps, canvasWidth: timeline.width, canvasHeight: timeline.height,
            startFrame: frame, durationFrames: try ClipPlacement.frames(seconds: asset.duration, fps: timeline.fps))
    }

    func publishSpeechAsset(_ asset: MediaAsset, clips: ClipPlacement.Clips?, trackName: String?) -> String? {
        let action = L10n.string("Generate Speech (Agent)")
        let before = mediaLibraryUndoSnapshot()
        undo.perform(action) {
            undo.withoutRegistration {
                importMediaAsset(asset)
                if let clip = clips?.primary {
                    let index = insertTrack(at: timeline.tracks.count, type: .audio)
                    timeline.tracks[index].name = trackName
                    timeline.tracks[index].clips.append(clip)
                }
            }
            undo.register(action, withTarget: self) { editor in
                editor.restoreMediaLibraryUndoSnapshot(before, actionName: action)
            }
            onProjectCheckpointRequired?()
        }
        searchIndex.schedule(asset)
        prepareMediaVisuals(for: asset)
        if clips != nil { notifyTimelineChanged() }
        return clips?.primary.id
    }
}
