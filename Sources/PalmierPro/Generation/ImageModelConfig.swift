import Foundation
import FalClient

struct ImageModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let resolutions: [String]?
    let aspectRatios: [String]

    func buildInput(prompt: String, aspectRatio: String, resolution: String?) -> Payload {
        var dict: [String: Payload] = [
            "prompt": .string(prompt),
            "output_format": .string("jpeg"),
        ]
        if !aspectRatio.isEmpty {
            dict["aspect_ratio"] = .string(aspectRatio)
        }
        if let resolution {
            dict["resolution"] = .string(resolution)
        }
        return .dict(dict)
    }
}

extension ImageModelConfig {
    static let nanaBananaPro = ImageModelConfig(
        id: "nano-banana-pro",
        displayName: "Nano Banana Pro",
        endpoint: "fal-ai/nano-banana-pro",
        resolutions: ["2K", "4K"],
        aspectRatios: ["16:9", "9:16"]
    )

    static let grokImagine = ImageModelConfig(
        id: "grok-imagine",
        displayName: "Grok Imagine",
        endpoint: "xai/grok-imagine-image",
        resolutions: nil,
        aspectRatios: ["16:9", "9:16"]
    )

    static let allModels: [ImageModelConfig] = [nanaBananaPro, grokImagine]
}
