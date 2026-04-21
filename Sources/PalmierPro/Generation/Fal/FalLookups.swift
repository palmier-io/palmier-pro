import Foundation
import FalClient

/// Output URL extractors keyed to each fal response shape.
enum FalResponsePaths {
    static let video: @Sendable (Payload) -> String? = { $0["video"]["url"].stringValue }
    static let generatedImage: @Sendable (Payload) -> String? = { $0["images"][0]["url"].stringValue }
    static let upscaledImage: @Sendable (Payload) -> String? = { $0["image"]["url"].stringValue }
}

/// Lookups across the three fal model registries (Video/Image/Upscale).
@MainActor
enum ModelRegistry {
    static func displayName(for modelId: String) -> String {
        if let v = VideoModelConfig.allModels.first(where: { $0.id == modelId }) { return v.displayName }
        if let i = ImageModelConfig.allModels.first(where: { $0.id == modelId }) { return i.displayName }
        if let u = UpscaleModelConfig.allModels.first(where: { $0.id == modelId }) { return u.displayName }
        return modelId
    }

    static func exists(id: String) -> Bool {
        if VideoModelConfig.allModels.contains(where: { $0.id == id }) { return true }
        if ImageModelConfig.allModels.contains(where: { $0.id == id }) { return true }
        if UpscaleModelConfig.allIds.contains(id) { return true }
        return false
    }
}
