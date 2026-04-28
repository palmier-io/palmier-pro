import AppKit

/// Project-level timeline settings: FPS, resolution, and the mismatch dialog that
/// surfaces when an imported clip's settings differ from the timeline's.
extension EditorViewModel {

    struct SettingsMismatch: Identifiable {
        let id = UUID()
        let clipFPS: Int
        let clipWidth: Int
        let clipHeight: Int
    }

    enum ProjectSettingsAction {
        case proceed
        case mismatch(clipFPS: Int, clipWidth: Int, clipHeight: Int)
    }

    func applyTimelineSettings(fps: Int, width: Int, height: Int) {
        let prevFPS = timeline.fps
        let prevWidth = timeline.width
        let prevHeight = timeline.height
        let prevConfigured = timeline.settingsConfigured

        // Rescale all frame-based values when FPS changes
        if fps != prevFPS {
            let scale = Double(fps) / Double(prevFPS)
            currentFrame = Int((Double(currentFrame) * scale).rounded())
            sourcePlayheadFrame = Int((Double(sourcePlayheadFrame) * scale).rounded())
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices {
                    let clip = timeline.tracks[ti].clips[ci]
                    timeline.tracks[ti].clips[ci].startFrame = Int((Double(clip.startFrame) * scale).rounded())
                    timeline.tracks[ti].clips[ci].durationFrames = max(1, Int((Double(clip.durationFrames) * scale).rounded()))
                    timeline.tracks[ti].clips[ci].trimStartFrame = Int((Double(clip.trimStartFrame) * scale).rounded())
                    timeline.tracks[ti].clips[ci].trimEndFrame = Int((Double(clip.trimEndFrame) * scale).rounded())
                    timeline.tracks[ti].clips[ci].audioFadeInFrames = Int((Double(clip.audioFadeInFrames) * scale).rounded())
                    timeline.tracks[ti].clips[ci].audioFadeOutFrames = Int((Double(clip.audioFadeOutFrames) * scale).rounded())
                    timeline.tracks[ti].clips[ci].clampFadesToDuration()
                }
            }
        }

        timeline.fps = fps
        timeline.width = width
        timeline.height = height
        timeline.settingsConfigured = true
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.applyTimelineSettings(fps: prevFPS, width: prevWidth, height: prevHeight)
            vm.timeline.settingsConfigured = prevConfigured
        }
        undoManager?.setActionName("Change Project Settings")
        notifyTimelineChanged()
    }

    func checkProjectSettings(for assets: [MediaAsset]) -> ProjectSettingsAction {
        guard let firstVideo = assets.first(where: { $0.type == .video }) else {
            return .proceed
        }

        let timelineIsEmpty = timeline.tracks.allSatisfy { $0.clips.isEmpty }

        if !timeline.settingsConfigured {
            // First clip ever — auto-detect settings silently
            let fps = firstVideo.sourceFPS.flatMap { Int($0.rounded()) } ?? timeline.fps
            let width = firstVideo.sourceWidth ?? timeline.width
            let height = firstVideo.sourceHeight ?? timeline.height
            applyTimelineSettings(fps: fps, width: width, height: height)
            return .proceed
        }

        if !timelineIsEmpty {
            return .proceed
        }

        // Timeline is empty but settings were previously configured — check for mismatch
        let clipFPS = firstVideo.sourceFPS.flatMap { Int($0.rounded()) }
        let clipWidth = firstVideo.sourceWidth
        let clipHeight = firstVideo.sourceHeight

        let fpsMismatch = clipFPS != nil && clipFPS != timeline.fps
        let resMismatch = (clipWidth != nil && clipWidth != timeline.width) ||
                          (clipHeight != nil && clipHeight != timeline.height)

        if fpsMismatch || resMismatch {
            return .mismatch(
                clipFPS: clipFPS ?? timeline.fps,
                clipWidth: clipWidth ?? timeline.width,
                clipHeight: clipHeight ?? timeline.height
            )
        }
        return .proceed
    }

    func addClipsWithSettingsCheck(assets: [MediaAsset], operation: @escaping @MainActor () -> Void) {
        let action = checkProjectSettings(for: assets)
        switch action {
        case .proceed:
            operation()
        case .mismatch(let clipFPS, let clipWidth, let clipHeight):
            pendingSettingsContinuation = operation
            pendingSettingsMismatch = SettingsMismatch(
                clipFPS: clipFPS,
                clipWidth: clipWidth,
                clipHeight: clipHeight
            )
        }
    }
}
