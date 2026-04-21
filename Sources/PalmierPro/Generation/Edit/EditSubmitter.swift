import Foundation
import FalClient

/// Builds and dispatches AI-tab submissions (Upscale, Rerun) pipeline.
@MainActor
enum EditSubmitter {

    // MARK: - Upscale

    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        editor: EditorViewModel,
        service: GenerationService,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard service.hasApiKey else { return nil }

        let duration = max(1, Int(asset.duration.rounded()))
        let genInput = GenerationInput(
            prompt: "",
            model: model.id,
            duration: duration,
            aspectRatio: "",
            resolution: nil
        )

        let isImage = asset.type == .image
        let placeholderDuration: Double = isImage
            ? Defaults.imageDurationSeconds
            : (asset.duration > 0 ? asset.duration : Double(duration))

        return service.generate(
            genInput: genInput,
            assetType: asset.type,
            placeholderDuration: placeholderDuration,
            references: [asset],
            name: upscaleName(for: asset),
            buildInput: { uploaded in
                let src = uploaded.first ?? ""
                return (model.endpoint, model.buildFalInput(src))
            },
            responseKeyPath: isImage ? FalResponsePaths.upscaledImage : FalResponsePaths.video,
            fileExtension: isImage ? "jpg" : "mp4",
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    // MARK: - Rerun

    enum RerunError: LocalizedError {
        case notGenerated
        case unknownModel(String)
        case missingSource

        var errorDescription: String? {
            switch self {
            case .notGenerated: "This asset was not AI-generated"
            case .unknownModel(let id): "Model no longer available: \(id)"
            case .missingSource: "Cannot rerun: source not recorded"
            }
        }
    }

    @discardableResult
    static func rerun(
        asset: MediaAsset,
        editor: EditorViewModel,
        service: GenerationService,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        guard service.hasApiKey else {
            throw RerunError.unknownModel("no api key")
        }
        guard let gen = asset.generationInput else { throw RerunError.notGenerated }
        let modelId = gen.model
        let preUploaded = gen.imageURLs

        if let videoModel = VideoModelConfig.allModels.first(where: { $0.id == modelId }) {
            if videoModel.requiresSourceVideo {
                guard let source = preUploaded?.first else { throw RerunError.missingSource }
                let imageRefs = Array((preUploaded ?? []).dropFirst())
                let params = VideoGenerationParams(
                    prompt: gen.prompt,
                    duration: gen.duration,
                    aspectRatio: gen.aspectRatio,
                    resolution: gen.resolution,
                    sourceVideoURL: source,
                    startFrameURL: nil,
                    endFrameURL: nil,
                    referenceImageURLs: imageRefs,
                    generateAudio: true
                )
                return service.generate(
                    genInput: gen,
                    assetType: .video,
                    placeholderDuration: asset.duration > 0 ? asset.duration : Double(max(1, gen.duration)),
                    references: [],
                    preUploadedURLs: preUploaded,
                    name: rerunName(for: asset),
                    buildInput: { _ in
                        (videoModel.resolvedEndpoint(params: params), videoModel.buildInput(params: params))
                    },
                    responseKeyPath: FalResponsePaths.video,
                    fileExtension: "mp4",
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }
            let params = VideoGenerationParams(
                prompt: gen.prompt,
                duration: gen.duration,
                aspectRatio: gen.aspectRatio,
                resolution: gen.resolution,
                sourceVideoURL: nil,
                startFrameURL: preUploaded?.first,
                endFrameURL: (preUploaded?.count ?? 0) > 1 ? preUploaded?[1] : nil,
                referenceImageURLs: [],
                generateAudio: true
            )
            return service.generate(
                genInput: gen,
                assetType: .video,
                placeholderDuration: Double(max(1, gen.duration)),
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                buildInput: { _ in
                    (videoModel.resolvedEndpoint(params: params), videoModel.buildInput(params: params))
                },
                responseKeyPath: FalResponsePaths.video,
                fileExtension: "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let imageModel = ImageModelConfig.allModels.first(where: { $0.id == modelId }) {
            return service.generate(
                genInput: gen,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                buildInput: { uploaded in
                    let input = imageModel.buildInput(
                        prompt: gen.prompt,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        imageURLs: uploaded
                    )
                    return (imageModel.resolvedEndpoint(imageURLs: uploaded), input)
                },
                responseKeyPath: FalResponsePaths.generatedImage,
                fileExtension: "jpg",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let upscaleModel = UpscaleModelConfig.allModels.first(where: { $0.id == modelId }) {
            guard let source = preUploaded?.first else { throw RerunError.missingSource }
            let isImage = asset.type == .image
            return service.generate(
                genInput: gen,
                assetType: asset.type,
                placeholderDuration: isImage
                    ? Defaults.imageDurationSeconds
                    : (asset.duration > 0 ? asset.duration : Double(gen.duration)),
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                buildInput: { _ in
                    (upscaleModel.endpoint, upscaleModel.buildFalInput(source))
                },
                responseKeyPath: isImage ? FalResponsePaths.upscaledImage : FalResponsePaths.video,
                fileExtension: isImage ? "jpg" : "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        throw RerunError.unknownModel(modelId)
    }

    // MARK: - Names

    private static func upscaleName(for asset: MediaAsset) -> String {
        "Upscaled \(stripPrefix(asset.name))"
    }

    private static func rerunName(for asset: MediaAsset) -> String {
        "Rerun \(stripPrefix(asset.name))"
    }

    private static func stripPrefix(_ name: String) -> String {
        for prefix in ["Upscaled ", "Edited ", "Rerun "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}
