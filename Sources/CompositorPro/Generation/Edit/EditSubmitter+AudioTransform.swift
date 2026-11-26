import Foundation

extension EditSubmitter {
    static func audioTransformSeed(
        for asset: MediaAsset,
        kind: AudioTransformEditKind,
        durationOverride: Double? = nil
    ) -> GenerationInput? {
        guard let model = kind.model else { return nil }
        let duration = max(1, Int((durationOverride ?? asset.duration).rounded()))
        var stored = GenerationInput(
            prompt: "",
            model: model.id,
            duration: duration,
            aspectRatio: "",
            resolution: nil
        )
        guard stored.setAudioSourceAsset(asset) else { return nil }
        return stored
    }
}
