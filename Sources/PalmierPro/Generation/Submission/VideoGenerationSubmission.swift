import Foundation

/// Shared video generation submission assembly for UI and agent entry points.
struct VideoGenerationSubmission {
    let genInput: GenerationInput
    let placeholderDuration: Double
    let references: [MediaAsset]
    let trimmedSourceOverride: TrimmedSource?
    let name: String?
    let folderId: String?
    let buildParams: ([String]) -> BackendGenerationParams
    let snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)?
    let preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?

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
            assetType: .video,
            placeholderDuration: placeholderDuration,
            references: references,
            trimmedSourceOverride: trimmedSourceOverride,
            name: name,
            folderId: folderId,
            buildParams: buildParams,
            snapshotRefs: snapshotRefs,
            preprocessRef: preprocessRef,
            fileExtension: "mp4",
            projectURL: projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    @MainActor
    static func make(
        genInput baseInput: GenerationInput,
        model: VideoModelConfig,
        inputAssets: InputAssets = InputAssets(),
        placeholderDuration: Double,
        trimmedSourceOverride: TrimmedSource? = nil,
        name: String? = nil,
        folderId: String? = nil,
        generateAudio: Bool
    ) -> VideoGenerationSubmission {
        var genInput = baseInput
        if model.requiresSourceVideo {
            let references = inputAssets.editReferences
            genInput.imageURLAssetIds = assetIds(references)

            return VideoGenerationSubmission(
                genInput: genInput,
                placeholderDuration: placeholderDuration,
                references: references,
                trimmedSourceOverride: trimmedSourceOverride,
                name: name,
                folderId: folderId,
                buildParams: { uploaded in
                    .video(VideoGenerationParams(
                        prompt: genInput.prompt,
                        duration: genInput.duration,
                        aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution,
                        sourceVideoURL: uploaded.first,
                        startFrameURL: nil,
                        endFrameURL: nil,
                        referenceImageURLs: Array(uploaded.dropFirst()),
                        generateAudio: generateAudio
                    ))
                },
                snapshotRefs: nil,
                preprocessRef: nil
            )
        }

        let frameCount = inputAssets.frames.count
        let imageRefCount = inputAssets.imageRefs.count
        let videoRefCount = inputAssets.videoRefs.count
        let audioRefCount = inputAssets.audioRefs.count
        let references = inputAssets.textToVideoReferences
        genInput.imageURLAssetIds = assetIds(inputAssets.frames)
        genInput.referenceImageAssetIds = assetIds(inputAssets.imageRefs)
        genInput.referenceVideoAssetIds = assetIds(inputAssets.videoRefs)
        genInput.referenceAudioAssetIds = assetIds(inputAssets.audioRefs)

        let snapshotRefs = videoInputSnapshotter(
            frameCount: frameCount,
            imageRefCount: imageRefCount,
            videoRefCount: videoRefCount,
            audioRefCount: audioRefCount
        )
        let preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?
        if inputAssets.videoRefs.isEmpty {
            preprocessRef = nil
        } else {
            preprocessRef = { _, asset in
                guard asset.type == .video else { return nil }
                return try await VideoCompressor.compressIfNeeded(url: asset.url)
            }
        }

        return VideoGenerationSubmission(
            genInput: genInput,
            placeholderDuration: placeholderDuration,
            references: references,
            trimmedSourceOverride: trimmedSourceOverride,
            name: name,
            folderId: folderId,
            buildParams: { uploaded in
                let params = videoInputURLs(
                    uploaded: uploaded,
                    frameCount: frameCount,
                    imageRefCount: imageRefCount,
                    videoRefCount: videoRefCount,
                    audioRefCount: audioRefCount
                ).params(
                    prompt: genInput.prompt,
                    duration: genInput.duration,
                    aspectRatio: genInput.aspectRatio,
                    resolution: genInput.resolution,
                    generateAudio: generateAudio
                )
                return .video(params)
            },
            snapshotRefs: snapshotRefs,
            preprocessRef: preprocessRef
        )
    }

    struct InputAssets {
        var sourceVideo: MediaAsset?
        var frames: [MediaAsset] = []
        var imageRefs: [MediaAsset] = []
        var videoRefs: [MediaAsset] = []
        var audioRefs: [MediaAsset] = []

        @MainActor
        var allRefs: [MediaAsset] {
            imageRefs + videoRefs + audioRefs
        }

        @MainActor
        var textToVideoReferences: [MediaAsset] {
            frames + allRefs
        }

        @MainActor
        var editReferences: [MediaAsset] {
            (sourceVideo.map { [$0] } ?? []) + imageRefs
        }

        @MainActor
        var totalRefCount: Int {
            allRefs.count
        }

        @MainActor
        func validate(for model: VideoModelConfig) -> String? {
            if model.requiresSourceVideo {
                return validateEditReferences(for: model)
            }
            return validateTextToVideoReferences(for: model)
        }

        @MainActor
        private func validateEditReferences(for model: VideoModelConfig) -> String? {
            guard let sourceVideo else {
                return L10n.format("Model '%@' requires a source video.", model.id)
            }
            guard sourceVideo.type == .video else {
                return L10n.string("sourceVideoMediaRef must reference a video asset")
            }
            if !frames.isEmpty || !videoRefs.isEmpty || !audioRefs.isEmpty {
                return L10n.format("%@ only accepts a source video and image references", model.displayName)
            }
            if !model.supportsReferences, !imageRefs.isEmpty {
                return L10n.format("%@ does not accept image references", model.displayName)
            }
            if imageRefs.count > model.maxReferenceImages {
                return L10n.format(
                    "%@ accepts at most %d image reference(s)",
                    model.displayName,
                    model.maxReferenceImages
                )
            }
            return validateTypes([
                (imageRefs, .image, "referenceImageMediaRefs")
            ])
        }

        @MainActor
        private func validateTextToVideoReferences(for model: VideoModelConfig) -> String? {
            if sourceVideo != nil {
                return L10n.format("%@ does not accept a source video", model.displayName)
            }
            if frames.count > 2 {
                return L10n.format("%@ accepts at most 2 frame references", model.displayName)
            }
            if !frames.isEmpty, !model.supportsFirstFrame {
                return L10n.format("%@ does not accept frame references", model.displayName)
            }
            if frames.count > 1, !model.supportsLastFrame {
                return L10n.format("%@ does not accept a last frame", model.displayName)
            }
            if model.framesAndReferencesExclusive, !frames.isEmpty, !allRefs.isEmpty {
                return L10n.format("%@ uses frames OR references, not both. Clear one side.", model.displayName)
            }
            if imageRefs.count > model.maxReferenceImages {
                return L10n.format(
                    "%@ accepts at most %d image references",
                    model.displayName,
                    model.maxReferenceImages
                )
            }
            if videoRefs.count > model.maxReferenceVideos {
                return L10n.format(
                    "%@ accepts at most %d video references",
                    model.displayName,
                    model.maxReferenceVideos
                )
            }
            if audioRefs.count > model.maxReferenceAudios {
                return L10n.format(
                    "%@ accepts at most %d audio references",
                    model.displayName,
                    model.maxReferenceAudios
                )
            }
            if let totalCap = model.maxTotalReferences, totalRefCount > totalCap {
                return L10n.format("%@ accepts at most %d references total", model.displayName, totalCap)
            }
            if let cap = model.maxCombinedVideoRefSeconds,
               videoRefs.reduce(0, { $0 + $1.duration }) > cap {
                return L10n.format("Combined video reference duration exceeds %ds", Int(cap))
            }
            if let cap = model.maxCombinedAudioRefSeconds,
               audioRefs.reduce(0, { $0 + $1.duration }) > cap {
                return L10n.format("Combined audio reference duration exceeds %ds", Int(cap))
            }
            return validateTypes([
                (frames, .image, "frame references"),
                (imageRefs, .image, "referenceImageMediaRefs"),
                (videoRefs, .video, "referenceVideoMediaRefs"),
                (audioRefs, .audio, "referenceAudioMediaRefs")
            ])
        }

        @MainActor
        private func validateTypes(_ groups: [([MediaAsset], ClipType, String)]) -> String? {
            for (assets, expected, label) in groups {
                for asset in assets where asset.type != expected {
                    return L10n.format(
                        "%@ entry '%@' must be a %@ asset",
                        label,
                        asset.id,
                        expected.rawValue
                    )
                }
            }
            return nil
        }
    }

    private struct UploadedInputURLs: Sendable {
        let frames: [String]
        let imageRefs: [String]
        let videoRefs: [String]
        let audioRefs: [String]

        func apply(to input: inout GenerationInput) {
            input.imageURLs = frames.isEmpty ? nil : frames
            input.referenceImageURLs = imageRefs.isEmpty ? nil : imageRefs
            input.referenceVideoURLs = videoRefs.isEmpty ? nil : videoRefs
            input.referenceAudioURLs = audioRefs.isEmpty ? nil : audioRefs
        }

        func params(
            prompt: String,
            duration: Int,
            aspectRatio: String,
            resolution: String?,
            generateAudio: Bool
        ) -> VideoGenerationParams {
            VideoGenerationParams(
                prompt: prompt,
                duration: duration,
                aspectRatio: aspectRatio,
                resolution: resolution,
                sourceVideoURL: nil,
                startFrameURL: frames.first,
                endFrameURL: frames.count > 1 ? frames[1] : nil,
                referenceImageURLs: imageRefs,
                referenceVideoURLs: videoRefs,
                referenceAudioURLs: audioRefs,
                generateAudio: generateAudio
            )
        }
    }

    private static func videoInputURLs(
        uploaded: [String],
        frameCount: Int,
        imageRefCount: Int,
        videoRefCount: Int,
        audioRefCount: Int
    ) -> UploadedInputURLs {
        let frames = Array(uploaded.prefix(frameCount))
        let rest = Array(uploaded.dropFirst(frameCount))
        return UploadedInputURLs(
            frames: frames,
            imageRefs: imageRefCount > 0 ? Array(rest.prefix(imageRefCount)) : [],
            videoRefs: videoRefCount > 0 ? Array(rest.dropFirst(imageRefCount).prefix(videoRefCount)) : [],
            audioRefs: audioRefCount > 0
                ? Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount))
                : []
        )
    }

    private static func videoInputSnapshotter(
        frameCount: Int,
        imageRefCount: Int,
        videoRefCount: Int,
        audioRefCount: Int
    ) -> @Sendable (inout GenerationInput, [String]) -> Void {
        { input, uploaded in
            videoInputURLs(
                uploaded: uploaded,
                frameCount: frameCount,
                imageRefCount: imageRefCount,
                videoRefCount: videoRefCount,
                audioRefCount: audioRefCount
            ).apply(to: &input)
        }
    }

    @MainActor
    private static func assetIds(_ assets: [MediaAsset]) -> [String]? {
        assets.isEmpty ? nil : assets.map(\.id)
    }
}
