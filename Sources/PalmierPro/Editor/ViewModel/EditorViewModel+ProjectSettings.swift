import AppKit

/// Project-level timeline settings: FPS, resolution, and the mismatch dialog that
/// surfaces when an imported clip's settings differ from the timeline's.
extension EditorViewModel {

    private struct ProjectSettingsSnapshot: Equatable {
        let timelines: [Timeline]
        let currentFrame: Int
        let sourcePlayheadFrame: Int
        let liveViewStates: [String: TimelineViewState]
    }

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
        let before = projectSettingsSnapshot()
        let prevFPS = timeline.fps
        let prevWidth = timeline.width
        let prevHeight = timeline.height

        // FPS is project-wide: rescale frame-based values in every timeline.
        if fps != prevFPS && prevFPS > 0 && fps > 0 {
            let scale = Double(fps) / Double(prevFPS)
            currentFrame = Int((Double(currentFrame) * scale).rounded())
            sourcePlayheadFrame = Int((Double(sourcePlayheadFrame) * scale).rounded())
            for i in timelines.indices {
                timelines[i].rescaleFrames(by: scale)
            }
            liveViewStates = liveViewStates.mapValues { vs in
                var vs = vs
                vs.playheadFrame = Int((Double(vs.playheadFrame) * scale).rounded())
                return vs
            }
        }

        // Keep visual scale proportional when the canvas aspect changes.
        if width != prevWidth || height != prevHeight {
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices {
                    var clip = timeline.tracks[ti].clips[ci]
                    guard let dims = sourceDimensions(for: clip),
                          prevWidth > 0, prevHeight > 0, width > 0, height > 0 else { continue }
                    let sourceAspect = Double(dims.width) / Double(dims.height)
                    let oldAspect = sourceAspect / (Double(prevWidth) / Double(prevHeight))
                    let newAspect = sourceAspect / (Double(width) / Double(height))

                    let scaleAnimated = clip.scaleTrack?.isActive ?? false
                    let oldFit = fitTransform(sourceWidth: dims.width, sourceHeight: dims.height, canvasWidth: prevWidth, canvasHeight: prevHeight)
                    if !scaleAnimated,
                       transformScale(clip.transform, matches: oldFit) {
                        let newFit = fitTransform(sourceWidth: dims.width, sourceHeight: dims.height, canvasWidth: width, canvasHeight: height)
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

        for i in timelines.indices {
            timelines[i].fps = fps
            timelines[i].settingsConfigured = true
        }
        timeline.width = width
        timeline.height = height
        guard before != projectSettingsSnapshot() else { return }
        registerTimelineUndo("Change Project Settings") { $0.restoreProjectSettings(before) }
        notifyTimelineChanged()
    }

    private func projectSettingsSnapshot() -> ProjectSettingsSnapshot {
        projectSettingsSnapshot(timelineIds: Set(timelines.map(\.id)))
    }

    private func projectSettingsSnapshot(timelineIds: Set<String>) -> ProjectSettingsSnapshot {
        ProjectSettingsSnapshot(
            timelines: timelines.filter { timelineIds.contains($0.id) },
            currentFrame: currentFrame,
            sourcePlayheadFrame: sourcePlayheadFrame,
            liveViewStates: liveViewStates.filter { timelineIds.contains($0.key) }
        )
    }

    private func restoreProjectSettings(_ target: ProjectSettingsSnapshot) {
        let timelineIds = Set(target.timelines.map(\.id))
        let current = projectSettingsSnapshot(timelineIds: timelineIds)
        guard current != target else { return }
        for timeline in target.timelines {
            guard let index = timelines.firstIndex(where: { $0.id == timeline.id }) else { continue }
            timelines[index] = timeline
        }
        currentFrame = target.currentFrame
        sourcePlayheadFrame = target.sourcePlayheadFrame
        for id in timelineIds {
            liveViewStates[id] = target.liveViewStates[id]
        }
        registerTimelineUndo("Change Project Settings") { $0.restoreProjectSettings(current) }
        notifyTimelineChanged()
    }

    private func transformScale(_ transform: Transform, matches other: Transform) -> Bool {
        abs(transform.width - other.width) < 0.0001 && abs(transform.height - other.height) < 0.0001
    }

    func checkProjectSettings(for assets: [MediaAsset], adoptFPS: Bool = true) -> ProjectSettingsAction {
        guard let firstVideo = assets.first(where: { $0.type == .video }) else {
            return .proceed
        }

        let timelineIsEmpty = timeline.tracks.allSatisfy { $0.clips.isEmpty }
        let canAdoptFPS = adoptFPS && timelines.allSatisfy { $0.tracks.allSatisfy { $0.clips.isEmpty } }

        if !timeline.settingsConfigured {
            // First clip ever — auto-detect settings silently
            let fps = canAdoptFPS ? (firstVideo.sourceFPS.flatMap { Int($0.rounded()) } ?? timeline.fps) : timeline.fps
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

        let fpsMismatch = canAdoptFPS && clipFPS != nil && clipFPS != timeline.fps
        let resMismatch = (clipWidth != nil && clipWidth != timeline.width) ||
                          (clipHeight != nil && clipHeight != timeline.height)

        if fpsMismatch || resMismatch {
            return .mismatch(
                clipFPS: canAdoptFPS ? (clipFPS ?? timeline.fps) : timeline.fps,
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

extension Timeline {
    mutating func rescaleFrames(by scale: Double) {
        for ti in tracks.indices {
            let clipIndices = tracks[ti].clips.indices.sorted {
                tracks[ti].clips[$0].startFrame < tracks[ti].clips[$1].startFrame
            }
            var previousEnd: Int?
            for ci in clipIndices {
                var clip = tracks[ti].clips[ci]
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
                tracks[ti].clips[ci] = clip
                previousEnd = clip.endFrame
            }
        }
    }
}
