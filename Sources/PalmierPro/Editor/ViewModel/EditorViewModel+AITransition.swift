import Foundation

extension EditorViewModel {
    static let maxTransitionSeconds: Double = 15

    static let defaultTransitionPrompt = """
        Create a seamless transition between the first frame and the last frame, one continuous \
        take. No weird movements, effects, or artifacts. Natural and consistent motion that makes \
        sense. No music, just appropriate SFX.
        """

    func transitionGapSeconds(lengthFrames: Int) -> Double {
        Double(lengthFrames) / Double(max(1, timeline.fps))
    }

    func beginAITransition(gap: GapSelection) {
        guard gap.range.start > 0, gap.range.length > 0,
              transitionGapSeconds(lengthFrames: gap.range.length) <= Self.maxTransitionSeconds,
              timeline.tracks.indices.contains(gap.trackIndex),
              let model = VideoModelConfig.allModels.first(where: {
                  !$0.requiresSourceVideo && $0.supportsFirstFrame && $0.supportsLastFrame
              }) else { return }
        let placement = PendingTransitionPlacement(
            timelineId: timeline.id,
            trackIndex: gap.trackIndex,
            gapStartFrame: gap.range.start,
            gapLengthFrames: gap.range.length
        )
        let gapSeconds = transitionGapSeconds(lengthFrames: placement.gapLengthFrames)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let startFrame = placement.gapStartFrame - 1
                let endFrame = placement.gapStartFrame + placement.gapLengthFrames
                let first = try await captureFrameToMedia(
                    source: .timeline(frame: startFrame),
                    name: "Transition start (frame \(startFrame))"
                )
                let last = try await captureFrameToMedia(
                    source: .timeline(frame: endFrame),
                    name: "Transition end (frame \(endFrame))"
                )
                var stored = GenerationInput(
                    prompt: Self.defaultTransitionPrompt, model: model.id,
                    duration: max(1, Int(gapSeconds.rounded())),
                    aspectRatio: "", resolution: nil
                )
                stored.imageURLAssetIds = [first.asset.id, last.asset.id]
                seedGenerationPanel(asset: first.asset, stored: stored, transitionPlacement: placement)
            } catch {
                mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }
        }
    }

    @discardableResult
    func placeGeneratingTransitionClip(placeholderId: String, placement: PendingTransitionPlacement) -> String? {
        guard activeTimelineId == placement.timelineId, transitionGapIsEmpty(placement),
              let asset = mediaAssets.first(where: { $0.id == placeholderId }) else {
            refuseWithToast("The gap is no longer available, so the transition will land in Media instead.")
            return nil
        }
        let before = timeline
        let ids = undo.withoutRegistration {
            placeClip(
                asset: asset,
                trackIndex: placement.trackIndex,
                startFrame: placement.gapStartFrame,
                durationFrames: placement.gapLengthFrames,
                addLinkedAudio: false
            )
        }
        guard let clipId = ids.first else {
            timeline = before
            return nil
        }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "AI Transition")
        notifyTimelineChanged()
        return clipId
    }

    func finalizeTransitionClip(placeholderId: String, asset: MediaAsset) {
        patchGeneratingClips(placeholderId: placeholderId) { clip, fps in
            let realFrames = max(1, secondsToFrame(seconds: asset.duration, fps: fps))
            clip.speed = Double(realFrames) / Double(max(1, clip.durationFrames))
            clip.trimStartFrame = 0
            clip.trimEndFrame = 0
        }
    }

    private func transitionGapIsEmpty(_ placement: PendingTransitionPlacement) -> Bool {
        guard timeline.tracks.indices.contains(placement.trackIndex) else { return false }
        let end = placement.gapStartFrame + placement.gapLengthFrames
        return !timeline.tracks[placement.trackIndex].clips.contains {
            $0.startFrame < end && $0.endFrame > placement.gapStartFrame
        }
    }
}
