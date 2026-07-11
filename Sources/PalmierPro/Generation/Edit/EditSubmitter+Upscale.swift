import Foundation

extension EditSubmitter {
    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn else { return nil }

        let effectiveDuration = effectiveDuration(for: asset, trimmedSource: trimmedSource)
        let genInput = GenerationInput(
            prompt: "",
            model: model.id,
            duration: effectiveDuration,
            aspectRatio: "",
            resolution: nil
        )

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
                    durationSeconds: isImage ? 1 : effectiveDuration
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
