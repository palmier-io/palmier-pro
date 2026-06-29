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
        if fps != prevFPS && prevFPS > 0 && fps > 0 {
            let scale = Double(fps) / Double(prevFPS)
            currentFrame = Int((Double(currentFrame) * scale).rounded())
            sourcePlayheadFrame = Int((Double(sourcePlayheadFrame) * scale).rounded())
            for ti in timeline.tracks.indices {
                let clipIndices = timeline.tracks[ti].clips.indices.sorted {
                    timeline.tracks[ti].clips[$0].startFrame < timeline.tracks[ti].clips[$1].startFrame
                }
                var previousEnd: Int?
                for ci in clipIndices {
                    var clip = timeline.tracks[ti].clips[ci]
                    let scaledStart = Int((Double(clip.startFrame) * scale).rounded())
                    let scaledEnd = Int((Double(clip.endFrame) * scale).rounded())
                    clip.startFrame = max(scaledStart, previousEnd ?? scaledStart)
                    clip.durationFrames = max(1, scaledEnd - clip.startFrame)
                    clip.trimStartFrame = Int((Double(clip.trimStartFrame) * scale).rounded())
                    clip.trimEndFrame = Int((Double(clip.trimEndFrame) * scale).rounded())
                    clip.rescaleKeyframes(by: scale)
                    clip.fadeInFrames = Int((Double(clip.fadeInFrames) * scale).rounded())
                    clip.fadeOutFrames = Int((Double(clip.fadeOutFrames) * scale).rounded())
                    clip.clampKeyframesToDuration()
                    clip.clampFadesToDuration()
                    timeline.tracks[ti].clips[ci] = clip
                    previousEnd = clip.endFrame
                }
            }
        }

        // Keep visual scale proportional when the canvas aspect changes.
        if width != prevWidth || height != prevHeight {
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices {
                    var clip = timeline.tracks[ti].clips[ci]
                    guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }),
                          let oldAspect = mediaCanvasAspect(for: asset, canvasWidth: prevWidth, canvasHeight: prevHeight),
                          let newAspect = mediaCanvasAspect(for: asset, canvasWidth: width, canvasHeight: height) else { continue }

                    let scaleAnimated = clip.scaleTrack?.isActive ?? false
                    let oldFit = fitTransform(for: asset, canvasWidth: prevWidth, canvasHeight: prevHeight)
                    if !scaleAnimated,
                       transformScale(clip.transform, matches: oldFit) {
                        let newFit = fitTransform(for: asset, canvasWidth: width, canvasHeight: height)
                        clip.transform.width = newFit.width
                        clip.transform.height = newFit.height
                    } else {
                        let heightScale = oldAspect / newAspect
                        clip.transform.height *= heightScale
                        if var track = clip.scaleTrack, track.isActive {
                            for ki in track.keyframes.indices {
                                track.keyframes[ki].value.b *= heightScale
                            }
                            clip.scaleTrack = track
                        }
                    }
                    timeline.tracks[ti].clips[ci] = clip
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

    private func transformScale(_ transform: Transform, matches other: Transform) -> Bool {
        abs(transform.width - other.width) < 0.0001 && abs(transform.height - other.height) < 0.0001
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
