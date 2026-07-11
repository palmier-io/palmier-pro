import SwiftUI

// Cost estimation, preflight validation, submission, and panel seeding/reset.
extension GenerationView {

    var canSubmit: Bool {
        guard canAffordGeneration else { return false }
        if selectedType == .video && videoModel.requiresSourceVideo {
            guard sourceVideo != nil else { return false }
            if videoModel.requiresReferenceImage && imageReferences.isEmpty { return false }
            if !videoModel.supportsReferences && isPromptEmpty { return false }
            return true
        }
        if selectedType == .video && videoModel.framesAndReferencesExclusive
            && framesRefsMode == .reference && refImages.isEmpty
            && refVideos.isEmpty && refAudios.isEmpty {
            return false
        }
        if selectedType == .audio {
            if audioModel.acceptsSourceMedia {
                guard audioSource != nil else { return false }
                guard let languages = audioModel.targetLanguages else { return true }
                return languages.contains(selectedTargetLanguage)
            }
            return trimmedPrompt.count >= audioModel.minPromptLength
        }
        return !isPromptEmpty
    }

    /// Live credit estimate for the current form state.
    private var estimatedCost: Int? {
        switch selectedType {
        case .video:
            return CostEstimator.videoCost(
                model: videoModel,
                durationSeconds: effectiveVideoSeconds,
                resolution: effectiveResolution,
                generateAudio: effectiveGenerateAudio
            )
        case .image:
            let quality = imageModel.qualities != nil ? selectedQuality : nil
            return CostEstimator.imageCost(
                model: imageModel,
                resolution: effectiveResolution,
                quality: quality,
                numImages: selectedNumImages
            )
        case .audio:
            let duration: Int? = audioModel.acceptsSourceMedia
                ? (audioSource == nil ? nil : effectiveAudioSourceSeconds)
                : (audioModel.durations != nil ? selectedAudioDuration : nil)
            return CostEstimator.audioCost(
                model: audioModel, prompt: trimmedPrompt, durationSeconds: duration
            )
        }
    }

    private var remainingCredits: Int? {
        guard let budget = AccountService.shared.budgetCredits else { return nil }
        return max(0, budget - AccountService.shared.spentCredits)
    }

    private var hasInsufficientCredits: Bool {
        guard let cost = estimatedCost, let left = remainingCredits else { return false }
        return cost > left
    }

    private var canAffordGeneration: Bool {
        guard let left = remainingCredits else { return true }
        if let cost = estimatedCost { return cost <= left }
        return left > 0
    }

    private var costHelpText: String {
        guard let cost = estimatedCost else {
            return "Estimated cost. Actual billing may differ slightly."
        }
        guard let left = remainingCredits else {
            return "\(cost) credits estimated. Actual billing may differ."
        }
        if cost > left {
            return "\(cost) credits needed. Only \(left.formatted()) remaining."
        }
        return "\(cost) credits. \((left - cost).formatted()) credits remaining after this generation."
    }

    var costEstimateLabel: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
            Text(estimatedCost.map { $0.formatted() } ?? "—")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(hasInsufficientCredits ? .red : AppTheme.Text.secondaryColor)
        .help(costHelpText)
    }

    var submitButton: some View {
        Button {
            if aiAllowed { submitGeneration() }
            else if !account.isMisconfigured { Task { await account.signInWithGoogle() } }
        } label: {
            Image(systemName: aiAllowed ? "arrow.up" : "person.crop.circle")
                .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .tint(AppTheme.Accent.primary)
        .disabled(aiAllowed ? !canSubmit : account.isMisconfigured || account.isSigningIn)
        .opacity((aiAllowed ? canSubmit : !account.isMisconfigured && !account.isSigningIn) ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
        .help(aiAllowed ? "" : (account.isMisconfigured ? "AI is unavailable" : account.isSigningIn ? "Opening Google" : "Sign in to generate"))
    }

    // MARK: - Actions

    func videoInputAssets(for model: VideoModelConfig) -> VideoGenerationSubmission.InputAssets {
        if model.requiresSourceVideo {
            return VideoGenerationSubmission.InputAssets(
                sourceVideo: sourceVideo,
                imageRefs: model.supportsReferences ? Array(imageReferences.prefix(1)) : []
            )
        }

        var frames: [MediaAsset] = []
        if showsFrameStrip {
            if let firstFrame { frames.append(firstFrame) }
            if let lastFrame { frames.append(lastFrame) }
        }
        return VideoGenerationSubmission.InputAssets(
            frames: frames,
            imageRefs: showsRefSections ? refImages : [],
            videoRefs: showsRefSections ? refVideos : [],
            audioRefs: showsRefSections ? refAudios : []
        )
    }

    private func preflightValidation(audioDuration: Int) -> String? {
        switch selectedType {
        case .video:
            let inputAssets = videoInputAssets(for: videoModel)
            let modelError: String?
            if videoModel.requiresSourceVideo {
                modelError = videoModel.validate(duration: 0, aspectRatio: "", resolution: nil)
            } else {
                modelError = videoModel.validate(
                    duration: selectedDuration,
                    aspectRatio: selectedAspectRatio,
                    resolution: effectiveResolution
                )
            }
            return modelError ?? inputAssets.validate(for: videoModel)
        case .image:
            let quality = imageModel.qualities != nil ? selectedQuality : nil
            let imageCount = imageModel.maxImages > 1
                ? min(imageModel.maxImages, max(1, selectedNumImages)) : 1
            return imageModel.validate(
                aspectRatio: selectedAspectRatio,
                resolution: effectiveResolution,
                quality: quality,
                imageRefCount: imageReferences.count,
                numImages: imageCount
            )
        case .audio:
            if audioModel.acceptsSourceMedia {
                guard audioSource != nil else { return "Add source media." }
                return audioModel.validate(spanSeconds: effectiveAudioSourceSpanSeconds)
                    ?? audioModel.validate(params: audioParams(audioDuration: audioDuration))
            }
            return audioModel.validate(params: audioParams(audioDuration: audioDuration))
        }
    }

    private func audioParams(audioDuration: Int, videoURL: String? = nil) -> AudioGenerationParams {
        AudioGenerationParams(
            prompt: prompt,
            voice: audioModel.voices != nil && !selectedVoice.isEmpty ? selectedVoice : nil,
            lyrics: audioModel.supportsLyrics && !lyrics.isEmpty ? lyrics : nil,
            styleInstructions: audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: audioModel.supportsInstrumental ? instrumental : false,
            durationSeconds: (audioModel.durations != nil || audioModel.acceptsSourceMedia) ? audioDuration : nil,
            videoURL: videoURL,
            sourceURL: nil,
            targetLanguage: audioModel.targetLanguages != nil ? selectedTargetLanguage : nil
        )
    }

    private func submitGeneration() {
        if currentModelLocked {
            SettingsWindowController.shared.show(tab: .account)
            return
        }
        let audioDuration: Int = {
            guard selectedType == .audio else { return 0 }
            if audioModel.acceptsSourceMedia { return effectiveAudioSourceSeconds }
            return audioModel.durations != nil ? selectedAudioDuration : 0
        }()
        if let err = preflightValidation(audioDuration: audioDuration) {
            flashDropError(err)
            return
        }
        var genInput = GenerationInput(
            prompt: prompt,
            model: currentModelId,
            duration: selectedType == .video ? effectiveVideoSeconds : audioDuration,
            aspectRatio: selectedAspectRatio,
            resolution: effectiveResolution,
            quality: selectedType == .image && imageModel.qualities != nil ? selectedQuality : nil,
            voice: selectedType == .audio && audioModel.voices != nil && !selectedVoice.isEmpty
                ? selectedVoice : nil,
            lyrics: selectedType == .audio && audioModel.supportsLyrics && !lyrics.isEmpty
                ? lyrics : nil,
            styleInstructions: selectedType == .audio && audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: selectedType == .audio && audioModel.supportsInstrumental
                ? instrumental : nil,
            targetLanguage: selectedType == .audio && audioModel.targetLanguages != nil
                ? selectedTargetLanguage : nil,
            generateAudio: supportsAudioToggle ? generateAudio : nil
        )
        let imageCount: Int = {
            guard selectedType == .image, imageModel.maxImages > 1 else { return 1 }
            return min(imageModel.maxImages, max(1, selectedNumImages))
        }()
        if imageCount > 1 {
            genInput.numImages = imageCount
        }

        let replacementClipId = editor.pendingEditReplacementClipId
        editor.pendingEditReplacementClipId = nil
        let pendingAudioPlacement = selectedType == .audio ? editor.pendingEditAudioPlacement : nil
        editor.pendingEditAudioPlacement = nil
        let editorRef = editor
        if let clipId = replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
        }
        let makeOnComplete: (Bool) -> (@MainActor (MediaAsset) -> Void)? = { resetTrim in
            guard let clipId = replacementClipId else { return nil }
            let firstOnly = FirstOnlyFlag()
            return { [weak editorRef] newAsset in
                guard firstOnly.fire() else { return }
                editorRef?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }
        let onFailure: (@MainActor () -> Void)? = {
            guard let clipId = replacementClipId else { return nil }
            return { [weak editorRef] in
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()

        let autoOpenPreview: (String) -> Void = { newAssetId in
            guard replacementClipId == nil else { return }
            editorRef.selectMediaPanelItem(newAssetId)
        }

        switch selectedType {
        case .video:
            let model = videoModel
            let inputAssets = videoInputAssets(for: model)
            let trimmedSource: TrimmedSource? = {
                guard model.requiresSourceVideo,
                      let trim = editor.pendingEditTrimmedSource,
                      let sv = sourceVideo,
                      trim.sourceURL == sv.url else { return nil }
                return trim
            }()
            editor.pendingEditTrimmedSource = nil
            let placeholderDuration: Double
            if model.requiresSourceVideo {
                if let trim = trimmedSource, trim.hasTrim {
                    placeholderDuration = trim.durationSeconds
                } else {
                    placeholderDuration = sourceVideo?.duration ?? 5
                }
            } else {
                placeholderDuration = Double(selectedDuration)
            }
            let videoFolderId: String? = editFolderId ?? (
                model.requiresSourceVideo
                    ? (inputAssets.sourceVideo?.folderId ?? inputAssets.imageRefs.last?.folderId)
                    : inputAssets.textToVideoReferences.last?.folderId
            ) ?? editor.mediaPanelCurrentFolderId
            let videoAssetId = VideoGenerationSubmission.make(
                genInput: genInput,
                model: model,
                inputAssets: inputAssets,
                placeholderDuration: placeholderDuration,
                trimmedSourceOverride: trimmedSource,
                folderId: videoFolderId,
                generateAudio: effectiveGenerateAudio
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: makeOnComplete(trimmedSource?.hasTrim == true),
                onFailure: onFailure
            )
            autoOpenPreview(videoAssetId)
        case .image:
            let model = imageModel
            let imageAssetId = ImageGenerationSubmission.make(
                genInput: genInput,
                model: model,
                references: imageReferences,
                numImages: imageCount,
                folderId: editFolderId ?? imageReferences.last?.folderId ?? editor.mediaPanelCurrentFolderId
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: makeOnComplete(false),
                onFailure: onFailure
            )
            autoOpenPreview(imageAssetId)
        case .audio:
            let model = audioModel
            let onCompleteAudio = makeOnComplete(false)
            let sourceAsset = model.acceptsSourceMedia ? audioSource : nil
            if let sourceAsset {
                genInput.setAudioSourceAsset(sourceAsset)
            }
            let audioOnComplete: (@MainActor (MediaAsset) -> Void)? = {
                guard pendingAudioPlacement != nil else { return onCompleteAudio }
                return { [weak editorRef] asset in
                    editorRef?.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                    onCompleteAudio?(asset)
                }
            }()
            let audioAssetId = AudioGenerationSubmission.make(
                genInput: genInput,
                model: model,
                params: audioParams(audioDuration: audioDuration),
                folderId: editFolderId
                    ?? sourceAsset?.folderId
                    ?? editor.mediaPanelCurrentFolderId,
                references: sourceAsset.map { [$0] } ?? [],
                trimmedSourceOverride: sourceAsset.flatMap(audioSourceTrimmedSource)
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: audioOnComplete,
                onFailure: onFailure
            )
            if let placement = pendingAudioPlacement {
                editor.placeGeneratingAudioClip(
                    placeholderId: audioAssetId,
                    startFrame: placement.startFrame,
                    spanSeconds: placement.spanSeconds,
                    actionName: placement.actionName
                )
            }
        }
        editor.pendingEditTrimmedSource = nil
        lyrics = ""
        styleInstructions = ""
        prompt = ""
        editFolderId = nil
        clearReferences()
    }

    // MARK: - Panel seeding / reset

    func consumePendingPanelSeed() {
        guard let seed = editor.pendingPanelSeed else { return }
        populatePanel(asset: seed.asset, stored: seed.stored)
        editor.pendingPanelSeed = nil
    }

    private func populatePanel(asset: MediaAsset, stored: GenerationInput) {
        switch ModelRegistry.byId[stored.model] {
        case .video:
            guard let idx = videoModels.firstIndex(where: { $0.id == stored.model }) else { return }
            isPopulatingPanel = true
            selectedType = .video
            selectedVideoModelIndex = idx
        case .image:
            guard let idx = imageModels.firstIndex(where: { $0.id == stored.model }) else { return }
            isPopulatingPanel = true
            selectedType = .image
            selectedImageModelIndex = idx
        case .audio:
            guard let idx = audioModels.firstIndex(where: { $0.id == stored.model }) else { return }
            isPopulatingPanel = true
            selectedType = .audio
            selectedAudioModelIndex = idx
        case .upscale, .none:
            return
        }
        defer { DispatchQueue.main.async { isPopulatingPanel = false } }

        prompt = stored.prompt
        if !stored.aspectRatio.isEmpty { selectedAspectRatio = stored.aspectRatio }
        if let r = stored.resolution { selectedResolution = r }
        if let q = stored.quality { selectedQuality = q }
        if stored.duration > 0 {
            selectedDuration = stored.duration
            selectedAudioDuration = stored.duration
        }
        if let n = stored.numImages { selectedNumImages = max(1, n) }
        if let v = stored.voice, !v.isEmpty { selectedVoice = v }
        if let language = stored.targetLanguage,
           audioModel.targetLanguages?.contains(language) == true {
            selectedTargetLanguage = language
        } else if selectedType == .audio {
            selectedTargetLanguage = initialAudioTargetLanguage
        }
        lyrics = stored.lyrics ?? ""
        styleInstructions = stored.styleInstructions ?? ""
        instrumental = stored.instrumental ?? false
        generateAudio = stored.generateAudio ?? true

        clearReferences()

        let assetsById = Dictionary(editor.mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lookup: (String) -> MediaAsset? = { assetsById[$0] }
        let primary = (stored.imageURLAssetIds ?? []).compactMap(lookup)

        switch selectedType {
        case .video:
            if videoModel.requiresSourceVideo {
                sourceVideo = primary.first
                if videoModel.supportsReferences, primary.count > 1 {
                    imageReferences = [primary[1]]
                }
            } else {
                if videoModel.supportsFirstFrame {
                    firstFrame = primary.first
                    if videoModel.supportsLastFrame, primary.count > 1 {
                        lastFrame = primary[1]
                    }
                }
                refImages = (stored.referenceImageAssetIds ?? []).compactMap(lookup)
                refVideos = (stored.referenceVideoAssetIds ?? []).compactMap(lookup)
                refAudios = (stored.referenceAudioAssetIds ?? []).compactMap(lookup)
                if videoModel.framesAndReferencesExclusive {
                    framesRefsMode = (!refImages.isEmpty || !refVideos.isEmpty || !refAudios.isEmpty)
                        ? .reference : .firstLast
                } else {
                    framesRefsMode = .firstLast
                }
            }
        case .image:
            imageReferences = primary
        case .audio:
            audioSource = (stored.referenceAudioAssetIds ?? []).compactMap(lookup).first
                ?? (stored.referenceVideoAssetIds ?? []).compactMap(lookup).first
        }

        editFolderId = asset.folderId

        resetSettings()
    }

    func resetAudioState() {
        let model = audioModel
        selectedVoice = model.defaultVoice ?? ""
        selectedTargetLanguage = initialAudioTargetLanguage
        if !model.supportsLyrics { lyrics = "" }
        if !model.supportsStyleInstructions { styleInstructions = "" }
        if !model.supportsInstrumental { instrumental = false }
        if let durations = model.durations, !durations.contains(selectedAudioDuration) {
            selectedAudioDuration = durations.first ?? 30
        }
    }

    func resetSettings() {
        if !currentAspectRatios.contains(selectedAspectRatio) {
            selectedAspectRatio = currentAspectRatios.first ?? "16:9"
        }
        if let resolutions = currentResolutions, !resolutions.contains(selectedResolution) {
            selectedResolution = resolutions.first ?? "1080p"
        }
        if let qualities = currentQualities, !qualities.contains(selectedQuality) {
            selectedQuality = qualities.last ?? "high"
        }
        if selectedType == .video, !videoModel.durations.contains(selectedDuration) {
            selectedDuration = videoModel.durations.first ?? 5
        }
        if selectedType == .video { generateAudio = true }
        if selectedType == .image {
            selectedNumImages = min(max(1, selectedNumImages), imageModel.maxImages)
        }
    }
}
