extension GenerationInput {
    @discardableResult
    mutating func setAudioSourceAsset(_ asset: MediaAsset) -> Bool {
        switch asset.type {
        case .audio:
            referenceAudioAssetIds = [asset.id]
            referenceVideoAssetIds = nil
        case .video:
            referenceVideoAssetIds = [asset.id]
            referenceAudioAssetIds = nil
        case .image, .text, .lottie, .sequence:
            return false
        }
        return true
    }
}
