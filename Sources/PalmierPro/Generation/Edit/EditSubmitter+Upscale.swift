import Foundation

extension EditSubmitter {
    static func upscaleSeed(
        for asset: MediaAsset,
        model: UpscaleModelConfig,
        trimmedSource: TrimmedSource? = nil
    ) -> GenerationInput {
        var input = GenerationInput(
            prompt: "",
            model: model.id,
            duration: effectiveDuration(for: asset, trimmedSource: trimmedSource),
            aspectRatio: "",
            resolution: nil,
            upscaleSettings: model.defaultSettings
        )
        input.imageURLAssetIds = [asset.id]
        input.upscaleSourceWidth = asset.sourceWidth
        input.upscaleSourceHeight = asset.sourceHeight
        input.upscaleSourceFPS = asset.sourceFPS
        return input
    }

    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        editor: EditorViewModel,
        settings: UpscaleSettings? = nil,
        trimmedSource: TrimmedSource? = nil,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn,
              asset.sourceWidth != nil, asset.sourceHeight != nil,
              model.supports(source: asset),
              asset.type != .video || asset.sourceFPS != nil else { return nil }

        let effectiveDuration = effectiveDuration(for: asset, trimmedSource: trimmedSource)
        var genInput = upscaleSeed(for: asset, model: model, trimmedSource: trimmedSource)
        let resolvedSettings = settings ?? model.defaultSettings
        genInput.upscaleSettings = resolvedSettings

        let isImage = asset.type == .image
        let placeholderDuration: Double
        if isImage {
            placeholderDuration = Defaults.imageDurationSeconds
        } else if let trim = trimmedSource, trim.hasTrim {
            placeholderDuration = trim.durationSeconds
        } else {
            placeholderDuration = asset.duration > 0 ? asset.duration : Double(effectiveDuration)
        }

        let sourceAssetId = asset.id
        return editor.generationService.generate(
            genInput: genInput,
            assetType: asset.type,
            placeholderDuration: placeholderDuration,
            references: [asset],
            trimmedSourceOverride: trimmedSource,
            name: prefixedName("Upscaled", for: asset),
            folderId: asset.folderId,
            buildParams: { uploaded in
                .upscale(UpscaleGenerationParams(
                    sourceURL: uploaded.first ?? "",
                    durationSeconds: isImage ? 1 : effectiveDuration,
                    sourceWidth: asset.sourceWidth,
                    sourceHeight: asset.sourceHeight,
                    sourceFPS: asset.sourceFPS,
                    settings: resolvedSettings
                ))
            },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
                input.imageURLAssetIds = [sourceAssetId]
            },
            fileExtension: isImage ? "jpg" : "mp4",
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }
}
