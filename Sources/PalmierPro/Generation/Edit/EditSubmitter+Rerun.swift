import Foundation

extension EditSubmitter {
    enum RerunError: LocalizedError {
        case notGenerated
        case unknownModel(String)
        case missingSource
        case invalid(String)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .notGenerated: "This asset was not AI-generated"
            case .unknownModel(let id): "Model no longer available: \(id)"
            case .missingSource: "Cannot rerun: source not recorded"
            case .invalid(let msg): msg
            case .unauthorized: "Subscribe to Palmier to rerun generations"
            }
        }
    }

    @discardableResult
    static func rerun(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        guard AccountService.shared.isSignedIn else {
            throw RerunError.unauthorized
        }
        guard let stored = asset.generationInput else { throw RerunError.notGenerated }
        var gen = stored
        gen.createdAt = nil
        let modelId = gen.model
        let preUploaded = gen.imageURLs

        if let videoModel = VideoModelConfig.allModels.first(where: { $0.id == modelId }) {
            if let err = videoModel.validate(
                duration: gen.duration, aspectRatio: gen.aspectRatio, resolution: gen.resolution
            ) {
                throw RerunError.invalid(err)
            }
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
                    generateAudio: gen.generateAudio ?? true
                )
                return editor.generationService.generate(
                    genInput: gen,
                    assetType: .video,
                    placeholderDuration: asset.duration > 0 ? asset.duration : Double(max(1, gen.duration)),
                    references: [],
                    preUploadedURLs: preUploaded,
                    name: prefixedName("Rerun", for: asset),
                    folderId: asset.folderId,
                    buildParams: { _ in .video(params) },
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
                referenceImageURLs: gen.referenceImageURLs ?? [],
                referenceVideoURLs: gen.referenceVideoURLs ?? [],
                referenceAudioURLs: gen.referenceAudioURLs ?? [],
                generateAudio: gen.generateAudio ?? true
            )
            let bundled = (preUploaded ?? [])
                + (gen.referenceImageURLs ?? [])
                + (gen.referenceVideoURLs ?? [])
                + (gen.referenceAudioURLs ?? [])
            return editor.generationService.generate(
                genInput: gen,
                assetType: .video,
                placeholderDuration: Double(max(1, gen.duration)),
                references: [],
                preUploadedURLs: bundled.isEmpty ? nil : bundled,
                name: prefixedName("Rerun", for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .video(params) },
                snapshotRefs: { _, _ in },
                fileExtension: "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let imageModel = ImageModelConfig.allModels.first(where: { $0.id == modelId }) {
            let count = min(imageModel.maxImages, max(1, gen.numImages ?? 1))
            let refCount = (preUploaded ?? []).count
            if let err = imageModel.validate(
                aspectRatio: gen.aspectRatio, resolution: gen.resolution, quality: gen.quality,
                imageRefCount: refCount, numImages: count
            ) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: [],
                preUploadedURLs: preUploaded,
                name: prefixedName("Rerun", for: asset),
                numImages: count,
                folderId: asset.folderId,
                buildParams: { uploaded in
                    .image(ImageGenerationParams(
                        prompt: gen.prompt,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        quality: gen.quality,
                        imageURLs: uploaded,
                        numImages: count
                    ))
                },
                fileExtension: "jpg",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let audioModel = AudioModelConfig.allModels.first(where: { $0.id == modelId }) {
            let hasRecordedSource = (gen.referenceAudioAssetIds?.isEmpty == false)
                || (gen.referenceVideoAssetIds?.isEmpty == false)
                || preUploaded?.first != nil
            let expectsSource = audioModel.acceptsSourceMedia
                && (!audioModel.inputs.contains(.text) || hasRecordedSource)
            let sourceURL = audioModel.usesSourceURL ? preUploaded?.first : nil
            let videoURL = audioModel.usesSourceURL ? nil : preUploaded?.first
            if expectsSource, sourceURL == nil, videoURL == nil {
                throw RerunError.missingSource
            }
            let placeholderDuration: Double = asset.duration > 0
                ? asset.duration
                : (audioModel.category == .music
                    ? Defaults.audioMusicDurationSeconds
                    : Defaults.audioTTSDurationSeconds)
            let params = AudioGenerationParams(
                prompt: gen.prompt,
                voice: gen.voice,
                lyrics: gen.lyrics,
                styleInstructions: gen.styleInstructions,
                instrumental: gen.instrumental ?? false,
                durationSeconds: (audioModel.durations != nil || expectsSource) && gen.duration > 0
                    ? gen.duration
                    : nil,
                videoURL: videoURL,
                sourceURL: sourceURL,
                targetLanguage: gen.targetLanguage
            )
            if let err = audioModel.validate(params: params) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .audio,
                placeholderDuration: placeholderDuration,
                references: [],
                preUploadedURLs: preUploaded,
                name: prefixedName("Rerun", for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .audio(params) },
                fileExtension: "mp3",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if UpscaleModelConfig.allModels.contains(where: { $0.id == modelId }) {
            guard let source = preUploaded?.first else { throw RerunError.missingSource }
            let isImage = asset.type == .image
            return editor.generationService.generate(
                genInput: gen,
                assetType: asset.type,
                placeholderDuration: isImage
                    ? Defaults.imageDurationSeconds
                    : (asset.duration > 0 ? asset.duration : Double(gen.duration)),
                references: [],
                preUploadedURLs: preUploaded,
                name: prefixedName("Rerun", for: asset),
                folderId: asset.folderId,
                buildParams: { _ in
                    .upscale(UpscaleGenerationParams(
                        sourceURL: source,
                        durationSeconds: isImage ? 1 : gen.duration
                    ))
                },
                fileExtension: isImage ? "jpg" : "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        throw RerunError.unknownModel(modelId)
    }
}
