import Foundation

extension EditorViewModel {
    static let maxTransitionSeconds: Double = 15

    func transitionGapSeconds(lengthFrames: Int) -> Double {
        Double(lengthFrames) / Double(max(1, timeline.fps))
    }

    func aiTransitionAvailability(for gap: GapSelection) -> (model: VideoModelConfig?, refusal: String?) {
        guard timeline.tracks.indices.contains(gap.trackIndex), gap.range.start > 0,
              gap.range.length > 0, timeline.tracks[gap.trackIndex].type == .video else { return (nil, nil) }
        let seconds = transitionGapSeconds(lengthFrames: gap.range.length)
        guard seconds <= Self.maxTransitionSeconds else {
            return (nil, "Transitions are limited to \(Int(Self.maxTransitionSeconds)) seconds. This gap is \(String(format: "%.1f", seconds)) seconds.")
        }
        guard aiEditAllowed else { return (nil, "Sign in to generate.") }
        let model = VideoModelConfig.firstAndLastFrame
        return (model, model == nil ? "No video model supports first and last frames." : nil)
    }

    func beginAITransition(gap: GapSelection) {
        guard let model = aiTransitionAvailability(for: gap).model else { return }
        let placement = PendingTransitionPlacement(
            timelineId: timeline.id,
            trackIndex: gap.trackIndex,
            gapStartFrame: gap.range.start,
            gapLengthFrames: gap.range.length
        )
        let gapSeconds = transitionGapSeconds(lengthFrames: placement.gapLengthFrames)
        cancelPendingTransitionSeed()
        transitionSeedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let startFrame = placement.gapStartFrame - 1
                let endFrame = placement.gapStartFrame + placement.gapLengthFrames
                guard transitionSeedIsCurrent(placement) else { return }
                let first = try await captureFrameToMedia(
                    source: .timeline(frame: startFrame),
                    name: "Transition start (frame \(startFrame))"
                )
                try Task.checkCancellation()
                guard transitionSeedIsCurrent(placement) else { return }
                let last = try await captureFrameToMedia(
                    source: .timeline(frame: endFrame),
                    name: "Transition end (frame \(endFrame))"
                )
                try Task.checkCancellation()
                guard transitionSeedIsCurrent(placement) else { return }
                let stored = EditSubmitter.transitionSeed(
                    model: model,
                    firstFrame: first.asset,
                    lastFrame: last.asset,
                    gapSeconds: gapSeconds
                )
                seedGenerationPanel(asset: first.asset, stored: stored, transitionPlacement: placement)
            } catch is CancellationError {
            } catch {
                mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }
        }
    }

    func transitionSeedIsCurrent(_ placement: PendingTransitionPlacement) -> Bool {
        activeTimelineId == placement.timelineId && transitionGapIsEmpty(placement)
    }

    func cancelPendingTransitionSeed() {
        transitionSeedTask?.cancel()
        transitionSeedTask = nil
    }

    @discardableResult
    func placeGeneratingTransitionClip(placeholderId: String, placement: PendingTransitionPlacement) -> String? {
        guard transitionSeedIsCurrent(placement),
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
