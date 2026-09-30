import Foundation

struct ImageGenerationSubmission {
    let genInput: GenerationInput
    let references: [MediaAsset]
    let name: String?
    let numImages: Int
    let folderId: String?
    let buildParams: ([String]) -> BackendGenerationParams

    @MainActor
    @discardableResult
    func submit(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        service.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: references,
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: buildParams,
            fileExtension: "jpg",
            projectURL: projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    @MainActor
    static func make(
        genInput baseInput: GenerationInput,
        model: ImageModelConfig,
        references: [MediaAsset],
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil
    ) -> ImageGenerationSubmission {
        var genInput = baseInput
        genInput.imageURLAssetIds = references.isEmpty ? nil : references.map(\.id)
        return ImageGenerationSubmission(
            genInput: genInput,
            references: references,
            name: name,
            numImages: numImages,
            folderId: folderId,
            buildParams: { uploaded in
                .image(ImageGenerationParams(
                    prompt: genInput.prompt,
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    quality: genInput.quality,
                    imageURLs: uploaded,
                    numImages: numImages
                ))
            }
        )
    }
}
