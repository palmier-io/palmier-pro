import Foundation

extension EditorViewModel {
    var aiEditAllowed: Bool {
        AccountService.shared.isSignedIn && !AccountService.shared.isMisconfigured
    }

    func aiEditActions(clipId: String) -> [EditAction] {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual else { return [] }
        return EditAction.available(
            for: asset,
            effectiveDurationOverride: aiEditTrimmedSource(clip: clip, asset: asset)?.durationSeconds
        )
    }

    func aiEditUpscaleModels(clipId: String) -> [UpscaleModelConfig] {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return [] }
        return UpscaleModelConfig.models(for: asset.type)
    }

    // MARK: - Clip-aware actions (trim + replace-on-complete where applicable)

    /// Edit: seed the panel with the trimmed range, replacing the clip's source on completion.
    func beginAIEdit(clipId: String) {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual,
              let stored = EditSubmitter.editSeed(for: asset) else { return }
        seedGenerationPanel(
            asset: asset,
            stored: stored,
            replacementClipId: clipId,
            trimmedSource: aiEditTrimmedSource(clip: clip, asset: asset)
        )
    }

    func runAIUpscale(clipId: String, model: UpscaleModelConfig) {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return }
        let trim = aiEditTrimmedSource(clip: clip, asset: asset)
        let handlers = clipReplacementHandlers(clipId: clipId, resetTrim: trim != nil)
        _ = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: self,
            trimmedSource: trim,
            onComplete: handlers.onComplete,
            onFailure: handlers.onFailure
        )
    }

    /// Music/SFX: output is new audio, so no source replacement — place it on the timeline at the clip.
    func beginAIVideoAudio(clipId: String, kind: VideoToAudioEditKind) {
        guard let (clip, asset) = aiEditClipAsset(clipId),
              let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        let trim = aiEditTrimmedSource(clip: clip, asset: asset)
        let span = trim?.durationSeconds
            ?? (asset.duration > 0 ? asset.duration : Double(clip.durationFrames) / Double(max(1, timeline.fps)))
        let placement = PendingAudioPlacement(
            startFrame: clip.startFrame,
            spanSeconds: max(span, 1 / Double(max(1, timeline.fps))),
            actionName: kind.timelineActionName
        )
        seedGenerationPanel(asset: asset, stored: stored, trimmedSource: trim, audioPlacement: placement)
    }

    func beginAIRerun(clipId: String) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        let modelId = asset.generationInput?.model ?? ""
        if UpscaleModelConfig.allIds.contains(modelId) {
            let handlers = clipReplacementHandlers(clipId: clipId, resetTrim: false)
            _ = try? EditSubmitter.rerun(
                asset: asset, editor: self,
                onComplete: handlers.onComplete, onFailure: handlers.onFailure
            )
        } else if let stored = asset.generationInput {
            seedGenerationPanel(asset: asset, stored: stored, replacementClipId: clipId)
        }
    }

    func beginAICreateVideo(clipId: String, asReference: Bool) {
        guard let (_, asset) = aiEditClipAsset(clipId),
              let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        seedGenerationPanel(asset: asset, stored: stored, replacementClipId: clipId)
    }

    func seedGenerationPanel(
        asset: MediaAsset,
        stored: GenerationInput,
        replacementClipId: String? = nil,
        trimmedSource: TrimmedSource? = nil,
        audioPlacement: PendingAudioPlacement? = nil
    ) {
        pendingEditReplacementClipId = replacementClipId
        pendingEditTrimmedSource = trimmedSource
        pendingEditAudioPlacement = audioPlacement
        pendingPanelSeed = PendingPanelSeed(asset: asset, stored: stored)
        showGenerationPanel = true
    }

    private func aiEditClipAsset(_ clipId: String) -> (clip: Clip, asset: MediaAsset)? {
        guard let clip = clipFor(id: clipId),
              let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return nil }
        return (clip, asset)
    }

    private func aiEditTrimmedSource(clip: Clip, asset: MediaAsset) -> TrimmedSource? {
        guard asset.type == .video, clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: asset.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: timeline.fps
        )
    }

    /// onComplete/onFailure for a direct (non-panel) submission that replaces the clip's source.
    private func clipReplacementHandlers(
        clipId: String,
        resetTrim: Bool
    ) -> (onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?) {
        markPendingReplacement(clipId: clipId)
        let fired = FirstOnlyFlag()
        let onComplete: @MainActor (MediaAsset) -> Void = { [weak self] newAsset in
            guard fired.fire() else { return }
            self?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
            self?.clearPendingReplacement(clipId: clipId)
        }
        let onFailure: @MainActor () -> Void = { [weak self] in
            self?.clearPendingReplacement(clipId: clipId)
        }
        return (onComplete, onFailure)
    }
}
