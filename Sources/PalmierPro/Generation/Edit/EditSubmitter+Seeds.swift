import Foundation

extension EditSubmitter {
    static let reframePrompt =
        "The exact same video as @Video1 but fill in to match the output aspect ratio. Keep movement, details, and audio the same as the original audio"

    static let transitionPrompt = """
        Create a seamless transition between the first frame and the last frame, one continuous \
        take. No weird movements, effects, or artifacts. Natural and consistent motion that makes \
        sense. No music, just appropriate SFX.
        """

    static func reframeSeed(
        for asset: MediaAsset,
        trimmedSource: TrimmedSource? = nil
    ) -> GenerationInput? {
        guard let model = VideoModelConfig.reframe else { return nil }
        return reframeSeed(for: asset, model: model, trimmedSource: trimmedSource)
    }

    static func reframeSeed(
        for asset: MediaAsset,
        model: VideoModelConfig,
        trimmedSource: TrimmedSource? = nil
    ) -> GenerationInput? {
        guard asset.type == .video,
              VideoModelConfig.isReframeModel(model) else { return nil }
        let isPortrait: Bool
        if let width = asset.sourceWidth, let height = asset.sourceHeight {
            isPortrait = height > width
        } else {
            isPortrait = false
        }
        let sourceSeconds = trimmedSource?.hasTrim == true
            ? trimmedSource?.durationSeconds ?? asset.resolvedDuration
            : asset.resolvedDuration
        var stored = GenerationInput(
            prompt: reframePrompt,
            model: model.id,
            duration: model.supportedDuration(covering: sourceSeconds),
            aspectRatio: isPortrait ? "16:9" : "9:16",
            resolution: model.preferredHighResolution
        )
        stored.referenceVideoAssetIds = [asset.id]
        return stored
    }

    static func transitionSeed(
        model: VideoModelConfig,
        firstFrame: MediaAsset,
        lastFrame: MediaAsset,
        gapSeconds: Double
    ) -> GenerationInput {
        var stored = GenerationInput(
            prompt: transitionPrompt,
            model: model.id,
            duration: model.nearestSupportedDuration(for: gapSeconds),
            aspectRatio: "",
            resolution: nil
        )
        stored.imageURLAssetIds = [firstFrame.id, lastFrame.id]
        return stored
    }

    static func editSeed(for asset: MediaAsset) -> GenerationInput? {
        let modelId: String
        switch asset.type {
        case .video:
            guard let model = VideoModelConfig.edit else { return nil }
            modelId = model.id
        case .image:
            guard let model = ImageModelConfig.nanoBananaPro else { return nil }
            modelId = model.id
        case .audio, .text, .lottie, .sequence, .subtitle:
            return nil
        }
        var stored = GenerationInput(
            prompt: "", model: modelId, duration: 0, aspectRatio: "", resolution: nil
        )
        stored.imageURLAssetIds = [asset.id]
        return stored
    }

    static func lipSyncSeed(
        for asset: MediaAsset,
        model: VideoModelConfig
    ) -> GenerationInput? {
        guard asset.type == .video, model.isLipSync else { return nil }
        var stored = GenerationInput(
            prompt: "", model: model.id, duration: 0, aspectRatio: "", resolution: nil
        )
        stored.imageURLAssetIds = [asset.id]
        return stored
    }

    static func createVideoSeed(for asset: MediaAsset, asReference: Bool) -> GenerationInput? {
        guard let model = VideoModelConfig.allModels.first(where: {
            !$0.requiresSourceVideo && (asReference ? $0.supportsReferences : $0.supportsFirstFrame)
        }) else { return nil }
        var stored = GenerationInput(
            prompt: "", model: model.id, duration: 0, aspectRatio: "", resolution: nil
        )
        if asReference {
            stored.referenceImageAssetIds = [asset.id]
        } else {
            stored.imageURLAssetIds = [asset.id]
        }
        return stored
    }

    static func videoAudioSeed(
        for asset: MediaAsset,
        kind: VideoToAudioEditKind
    ) -> GenerationInput? {
        guard asset.type == .video, let model = kind.model else { return nil }
        var stored = GenerationInput(
            prompt: "",
            model: model.id,
            duration: max(0, Int(asset.duration.rounded())),
            aspectRatio: "",
            resolution: nil
        )
        guard stored.setAudioSourceAsset(asset) else { return nil }
        return stored
    }
}
