import Foundation

extension GenerationInput {
    struct VideoInputURLs: Sendable {
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

    @MainActor
    mutating func setImageReferenceAssets(_ assets: [MediaAsset]) {
        imageURLAssetIds = Self.assetIds(assets)
    }

    @MainActor
    mutating func setVideoEditInputAssets(_ assets: [MediaAsset]) {
        imageURLAssetIds = Self.assetIds(assets)
    }

    @MainActor
    mutating func setVideoInputAssets(
        frames: [MediaAsset],
        images: [MediaAsset],
        videos: [MediaAsset],
        audios: [MediaAsset]
    ) {
        imageURLAssetIds = Self.assetIds(frames)
        referenceImageAssetIds = Self.assetIds(images)
        referenceVideoAssetIds = Self.assetIds(videos)
        referenceAudioAssetIds = Self.assetIds(audios)
    }

    static func videoInputURLs(
        uploaded: [String],
        frameCount: Int,
        imageRefCount: Int,
        videoRefCount: Int,
        audioRefCount: Int
    ) -> VideoInputURLs {
        let frames = Array(uploaded.prefix(frameCount))
        let rest = Array(uploaded.dropFirst(frameCount))
        return VideoInputURLs(
            frames: frames,
            imageRefs: imageRefCount > 0 ? Array(rest.prefix(imageRefCount)) : [],
            videoRefs: videoRefCount > 0 ? Array(rest.dropFirst(imageRefCount).prefix(videoRefCount)) : [],
            audioRefs: audioRefCount > 0
                ? Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount))
                : []
        )
    }

    static func videoInputSnapshotter(
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
