import Foundation

extension EditSubmitter {
    static func editSeed(for asset: MediaAsset) -> GenerationInput? {
        let modelId: String
        switch asset.type {
        case .video:
            guard let model = VideoModelConfig.allModels.first(where: { $0.requiresSourceVideo }) else {
                return nil
            }
            modelId = model.id
        case .image:
            guard let model = ImageModelConfig.nanoBananaPro else { return nil }
            modelId = model.id
        case .audio, .text, .lottie, .sequence:
            return nil
        }
        var stored = GenerationInput(
            prompt: "", model: modelId, duration: 0, aspectRatio: "", resolution: nil
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
