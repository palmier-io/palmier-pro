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
    let preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)?

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
            preprocessSourceVideo: preprocessSourceVideo,
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
        let outputName = name ?? (model.supportsPrompt ? nil : model.displayName)
        if model.requiresSourceVideo {
            let sourceCount = inputAssets.sourceVideo == nil ? 0 : 1
            let imageRefCount = inputAssets.imageRefs.count
            let videoRefCount = inputAssets.videoRefs.count
            let audioRefCount = inputAssets.audioRefs.count
            let references = inputAssets.editReferences
            let sourceVideoDuration = trimmedSourceOverride?.hasTrim == true
                ? trimmedSourceOverride?.durationSeconds
                : inputAssets.sourceVideo?.resolvedDuration
            genInput.imageURLAssetIds = assetIds(inputAssets.sourceVideo.map { [$0] } ?? [])
            genInput.referenceImageAssetIds = assetIds(inputAssets.imageRefs)
            genInput.referenceVideoAssetIds = assetIds(inputAssets.videoRefs)
            genInput.referenceAudioAssetIds = assetIds(inputAssets.audioRefs)
            let maxSourceVideoResolution = model.caps.maxSourceVideoResolution
            let requiredSourceVideoEncoding = model.caps.requiredSourceVideoEncoding
            let preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)?
            if maxSourceVideoResolution != nil || requiredSourceVideoEncoding != nil {
                preprocessSourceVideo = { @Sendable url in
                    try await VideoPreprocessor.transcodeIfNeeded(
                        url: url,
                        maxResolution: maxSourceVideoResolution,
                        requiredEncoding: requiredSourceVideoEncoding
                    )
                }
            } else {
                preprocessSourceVideo = nil
            }
            let snapshotRefs = videoInputSnapshotter(
                frameCount: sourceCount,
                imageRefCount: imageRefCount,
                videoRefCount: videoRefCount,
                audioRefCount: audioRefCount
            )

            return VideoGenerationSubmission(
                genInput: genInput,
                placeholderDuration: placeholderDuration,
                references: references,
                trimmedSourceOverride: trimmedSourceOverride,
                name: outputName,
                folderId: folderId,
                buildParams: { uploaded in
                    let urls = videoInputURLs(
                        uploaded: uploaded,
                        frameCount: sourceCount,
                        imageRefCount: imageRefCount,
                        videoRefCount: videoRefCount,
                        audioRefCount: audioRefCount
                    )
                    return .video(VideoGenerationParams(
                        prompt: genInput.prompt,
                        duration: genInput.duration,
                        aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution,
                        sourceVideoDuration: sourceVideoDuration,
                        sourceVideoURL: urls.frames.first,
                        startFrameURL: nil,
                        endFrameURL: nil,
                        referenceImageURLs: urls.imageRefs,
                        referenceVideoURLs: urls.videoRefs,
                        referenceAudioURLs: urls.audioRefs,
                        generateAudio: generateAudio
                    ))
                },
                snapshotRefs: snapshotRefs,
                preprocessRef: nil,
                preprocessSourceVideo: preprocessSourceVideo
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
                return try await VideoPreprocessor.downscaleIfNeeded(url: asset.url)
            }
        }

        return VideoGenerationSubmission(
            genInput: genInput,
            placeholderDuration: placeholderDuration,
            references: references,
            trimmedSourceOverride: trimmedSourceOverride,
            name: outputName,
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
            preprocessRef: preprocessRef,
            preprocessSourceVideo: nil
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
            (sourceVideo.map { [$0] } ?? []) + allRefs
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
                return "Model '\(model.id)' requires a source video."
            }
            guard sourceVideo.type == .video else {
                return "sourceVideoMediaRef must reference a video asset"
            }
            if !frames.isEmpty {
                return "\(model.displayName) does not accept frame references"
            }
            if model.requiresReferenceImage && imageRefs.isEmpty {
                return "\(model.displayName) requires an image reference"
            }
            if model.requiresReferenceAudio && audioRefs.isEmpty {
                return "\(model.displayName) requires an audio reference"
            }
            return validateReferences(for: model, includingFrames: false)
        }

        @MainActor
        private func validateTextToVideoReferences(for model: VideoModelConfig) -> String? {
            if sourceVideo != nil {
                return "\(model.displayName) does not accept a source video"
            }
            if frames.count > 2 {
                return "\(model.displayName) accepts at most 2 frame references"
            }
            if !frames.isEmpty, !model.supportsFirstFrame {
                return "\(model.displayName) does not accept frame references"
            }
            if frames.count > 1, !model.supportsLastFrame {
                return "\(model.displayName) does not accept a last frame"
            }
            if model.framesAndReferencesExclusive, !frames.isEmpty, !allRefs.isEmpty {
                return "\(model.displayName) uses frames OR references, not both. Clear one side."
            }
            return validateReferences(for: model, includingFrames: true)
        }

        @MainActor
        private func validateReferences(
            for model: VideoModelConfig,
            includingFrames: Bool
        ) -> String? {
            let referenceLabel = model.requiresSourceVideo ? "reference(s)" : "references"
            if imageRefs.count > model.maxReferenceImages {
                return "\(model.displayName) accepts at most \(model.maxReferenceImages) image \(referenceLabel)"
            }
            if videoRefs.count > model.maxReferenceVideos {
                return "\(model.displayName) accepts at most \(model.maxReferenceVideos) video \(referenceLabel)"
            }
            if audioRefs.count > model.maxReferenceAudios {
                return "\(model.displayName) accepts at most \(model.maxReferenceAudios) audio \(referenceLabel)"
            }
            if let totalCap = model.maxTotalReferences, totalRefCount > totalCap {
                return "\(model.displayName) accepts at most \(totalCap) references total"
            }
            if let cap = model.maxCombinedVideoRefSeconds,
               videoRefs.reduce(0, { $0 + $1.duration }) > cap {
                return "Combined video reference duration exceeds \(Int(cap))s"
            }
            if let cap = model.maxCombinedAudioRefSeconds,
               audioRefs.reduce(0, { $0 + $1.duration }) > cap {
                return "Combined audio reference duration exceeds \(Int(cap))s"
            }
            var groups: [([MediaAsset], ClipType, String)] = [
                (imageRefs, .image, "referenceImageMediaRefs"),
                (videoRefs, .video, "referenceVideoMediaRefs"),
                (audioRefs, .audio, "referenceAudioMediaRefs")
            ]
            if includingFrames {
                groups.insert((frames, .image, "frame references"), at: 0)
            }
            return validateTypes(groups)
        }

        @MainActor
        private func validateTypes(_ groups: [([MediaAsset], ClipType, String)]) -> String? {
            for (assets, expected, label) in groups {
                for asset in assets where asset.type != expected {
                    return "\(label) entry '\(asset.id)' must be a \(expected.rawValue) asset"
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
