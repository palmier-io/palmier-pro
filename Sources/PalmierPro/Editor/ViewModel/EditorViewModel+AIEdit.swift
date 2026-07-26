import Foundation

extension EditorViewModel {
    var aiEditAllowed: Bool {
        AccountService.shared.isSignedIn && !AccountService.shared.isMisconfigured
    }

    func aiEditActions(clipId: String) -> [EditAction] {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual else { return [] }
        return EditAction.available(
            for: asset,
            effectiveDurationOverride: aiEditTrimmedSource(clipId: clipId)?.durationSeconds
        )
    }

    func aiAudioTransformKinds(clipId: String) -> [AudioTransformEditKind] {
        guard let (clip, asset) = aiEditClipAsset(clipId),
              clip.mediaType == .audio || clip.mediaType.isVisual else { return [] }
        let duration = aiEditTrimmedSource(clipId: clipId)?.durationSeconds
        return AudioTransformEditKind.available(
            for: asset,
            effectiveDurationOverride: duration
        )
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
            trimmedSource: aiEditTrimmedSource(clipId: clipId)
        )
    }

    func beginAIUpscale(clipId: String, model: UpscaleModelConfig? = nil) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        let trim = aiEditTrimmedSource(clipId: clipId)
        let candidates = model.map { [$0] } ?? UpscaleModelConfig.models(for: asset.type)
        guard let selected = candidates.first(where: { $0.supports(source: asset) }) else { return }
        seedGenerationPanel(
            asset: asset,
            stored: EditSubmitter.upscaleSeed(for: asset, model: selected, trimmedSource: trim),
            replacementClipId: clipId,
            trimmedSource: trim
        )
    }

    /// Music/SFX: output is new audio, so no source replacement — place it on the timeline at the clip.
    func beginAIVideoAudio(clipId: String, kind: VideoToAudioEditKind) {
        guard let (_, asset) = aiEditClipAsset(clipId),
              let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        let trim = aiEditTrimmedSource(clipId: clipId)
        guard let placement = aiAudioPlacement(
            clipId: clipId,
            trimmedSource: trim,
            actionName: kind.timelineActionName
        ) else { return }
        seedGenerationPanel(asset: asset, stored: stored, trimmedSource: trim, audioPlacement: placement)
    }

    func beginAIAudioTransform(
        clipId: String,
        kind: AudioTransformEditKind,
        useTrimmedClip: Bool = true,
        placeOnTimeline: Bool = true
    ) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        let trim = useTrimmedClip ? aiEditTrimmedSource(clipId: clipId) : nil
        let placement = placeOnTimeline
            ? aiAudioPlacement(
                clipId: clipId,
                trimmedSource: trim,
                actionName: kind.timelineActionName
            )
            : nil
        if placeOnTimeline && placement == nil { return }
        guard let stored = EditSubmitter.audioTransformSeed(
            for: asset,
            kind: kind,
            durationOverride: placement?.spanSeconds ?? trim?.durationSeconds
        ) else { return }
        seedGenerationPanel(
            asset: asset,
            stored: stored,
            trimmedSource: trim,
            audioPlacement: placement
        )
    }

    func beginAIRerun(clipId: String) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        if let stored = asset.generationInput {
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
        audioPlacement: PendingAudioPlacement? = nil,
        transitionPlacement: PendingTransitionPlacement? = nil
    ) {
        if transitionPlacement == nil { cancelPendingTransitionSeed() }
        pendingEditReplacementClipId = replacementClipId
        pendingEditTrimmedSource = trimmedSource
        pendingEditAudioPlacement = audioPlacement
        pendingEditTransitionPlacement = transitionPlacement
        pendingPanelSeed = PendingPanelSeed(asset: asset, stored: stored)
        showGenerationPanel = true
    }

    func clearPendingGenerationPanelState(preservingReplacement: Bool = false) {
        cancelPendingTransitionSeed()
        if !preservingReplacement { pendingEditReplacementClipId = nil }
        pendingEditTrimmedSource = nil
        pendingEditAudioPlacement = nil
        pendingEditTransitionPlacement = nil
        pendingPanelSeed = nil
    }

    private func aiEditClipAsset(_ clipId: String) -> (clip: Clip, asset: MediaAsset)? {
        guard let clip = clipFor(id: clipId),
              let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return nil }
        return (clip, asset)
    }

    func aiEditTrimmedSource(clipId: String) -> TrimmedSource? {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return nil }
        guard asset.type == .video || asset.type == .audio,
              clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: asset.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: timeline.fps
        )
    }

    func aiAudioPlacement(
        clipId: String,
        trimmedSource: TrimmedSource?,
        actionName: String
    ) -> PendingAudioPlacement? {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return nil }
        let span = trimmedSource?.durationSeconds
            ?? (asset.duration > 0
                ? asset.duration
                : Double(clip.durationFrames) / Double(max(1, timeline.fps)))
        return PendingAudioPlacement(
            startFrame: clip.startFrame,
            spanSeconds: max(span, 1 / Double(max(1, timeline.fps))),
            actionName: actionName
        )
    }

}
