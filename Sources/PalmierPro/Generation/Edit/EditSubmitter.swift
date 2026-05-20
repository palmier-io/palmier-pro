import Foundation

/// Builds and dispatches AI-tab submissions (Upscale, Rerun) pipeline.
@MainActor
enum EditSubmitter {

    // MARK: - Upscale

    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isPaid else { return nil }

        let effectiveDuration: Int = {
            if let trim = trimmedSource, trim.hasTrim {
                return max(1, Int(trim.durationSeconds.rounded()))
            }
            return max(1, Int(asset.duration.rounded()))
        }()
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

        return editor.generationService.generate(
            genInput: genInput,
            assetType: asset.type,
            placeholderDuration: placeholderDuration,
            references: [asset],
            trimmedSourceOverride: trimmedSource,
            name: upscaleName(for: asset),
            folderId: asset.folderId,
            buildParams: { uploaded in
                .upscale(UpscaleGenerationParams(
                    sourceURL: uploaded.first ?? "",
                    durationSeconds: isImage ? 1 : effectiveDuration
                ))
            },
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
        guard AccountService.shared.isPaid else {
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
                    name: rerunName(for: asset),
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
                name: rerunName(for: asset),
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
                name: rerunName(for: asset),
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
                durationSeconds: audioModel.durations != nil && gen.duration > 0 ? gen.duration : nil
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
                name: rerunName(for: asset),
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
                name: rerunName(for: asset),
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
