import Foundation

extension VideoModelConfig {
    @MainActor
    static var reframe: VideoModelConfig? {
        allModels.first(where: { $0.operation == .reframe })
    }
}

extension EditSubmitter {
    static func reframeAvailability(
        for asset: MediaAsset,
        trimmedSource: TrimmedSource? = nil
    ) -> EditActionAvailability {
        guard asset.type == .video else {
            return .disabled(reason: "Reframe only works on video")
        }
        guard let model = VideoModelConfig.reframe else {
            return .disabled(reason: "Reframe model not available")
        }
        if asset.isGenerating {
            return .disabled(reason: "Generation in progress")
        }
        let duration = trimmedSource?.hasTrim == true
            ? trimmedSource?.durationSeconds ?? asset.duration
            : asset.duration
        guard duration > 0 else {
            return .disabled(reason: "Loading video metadata…")
        }
        if let maximum = model.maxSourceDurationSeconds, duration > maximum {
            return .disabled(
                reason: "Reframe supports up to \(Int(maximum))s (this is \(Int(duration.rounded()))s)"
            )
        }
        return .available
    }

    @discardableResult
    static func submitReframe(
        asset: MediaAsset,
        aspectRatio: String,
        resolution: String,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        name: String? = nil,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn,
              let model = VideoModelConfig.reframe,
              reframeAvailability(for: asset, trimmedSource: trimmedSource).isAvailable else {
            return nil
        }

        let duration = effectiveDuration(for: asset, trimmedSource: trimmedSource)
        guard model.validate(
            duration: duration,
            aspectRatio: aspectRatio,
            resolution: resolution
        ) == nil else {
            return nil
        }

        var genInput = GenerationInput(
            prompt: "",
            model: model.id,
            duration: duration,
            aspectRatio: aspectRatio,
            resolution: resolution
        )
        genInput.generateAudio = false

        let placeholderDuration = trimmedSource?.hasTrim == true
            ? trimmedSource?.durationSeconds ?? Double(duration)
            : (asset.duration > 0 ? asset.duration : Double(duration))
        let inputAssets = VideoGenerationSubmission.InputAssets(sourceVideo: asset)
        return VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: placeholderDuration,
            trimmedSourceOverride: trimmedSource,
            name: name ?? prefixedName("Reframed", for: asset),
            folderId: asset.folderId,
            generateAudio: false
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }
}
