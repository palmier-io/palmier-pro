import Foundation
import FalClient

struct ImageModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let baseEndpoint: String
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsImageReference: Bool
    let resolveEndpoint: @Sendable (_ base: String, _ imageURLs: [String]) -> String
    let buildFalInput: @Sendable (_ prompt: String, _ aspectRatio: String, _ resolution: String?, _ imageURLs: [String]) -> Payload

    func resolvedEndpoint(imageURLs: [String]) -> String {
        resolveEndpoint(baseEndpoint, imageURLs)
    }

    func buildInput(prompt: String, aspectRatio: String, resolution: String?, imageURLs: [String] = []) -> Payload {
        buildFalInput(prompt, aspectRatio, resolution, imageURLs)
    }
}

// MARK: - Shared builders

private func editEndpoint(_ base: String, _ imageURLs: [String]) -> String {
    imageURLs.isEmpty ? base : "\(base)/edit"
}

private func standardInput(prompt: String, aspectRatio: String, resolution: String?, imageURLs: [String]) -> Payload {
    var d: [String: Payload] = ["prompt": .string(prompt), "output_format": .string("jpeg")]
    if !aspectRatio.isEmpty { d["aspect_ratio"] = .string(aspectRatio) }
    if let resolution { d["resolution"] = .string(resolution) }
    if !imageURLs.isEmpty { d["image_urls"] = .array(imageURLs.map { .string($0) }) }
    return .dict(d)
}

// MARK: - Models

extension ImageModelConfig {
    static let nanoBananaPro = ImageModelConfig(
        id: "nano-banana-pro", displayName: "Nano Banana Pro",
        baseEndpoint: "fal-ai/nano-banana-pro",
        resolutions: ["2K", "4K"], aspectRatios: ["16:9", "9:16"],
        supportsImageReference: true,
        resolveEndpoint: editEndpoint, buildFalInput: standardInput
    )

    static let nanoBanana2 = ImageModelConfig(
        id: "nano-banana-2", displayName: "Nano Banana 2",
        baseEndpoint: "fal-ai/nano-banana-2",
        resolutions: ["2K", "4K"], aspectRatios: ["16:9", "9:16"],
        supportsImageReference: true,
        resolveEndpoint: editEndpoint, buildFalInput: standardInput
    )

    static let grokImagine = ImageModelConfig(
        id: "grok-imagine", displayName: "Grok Imagine",
        baseEndpoint: "xai/grok-imagine-image",
        resolutions: nil, aspectRatios: ["16:9", "9:16"],
        supportsImageReference: true,
        resolveEndpoint: editEndpoint,
        buildFalInput: { prompt, aspectRatio, _, imageURLs in
            var d: [String: Payload] = ["prompt": .string(prompt)]
            if !imageURLs.isEmpty {
                d["image_urls"] = .array(imageURLs.map { .string($0) })
            } else if !aspectRatio.isEmpty {
                d["aspect_ratio"] = .string(aspectRatio)
            }
            return .dict(d)
        }
    )

    static let recraftV4 = ImageModelConfig(
        id: "recraft-v4", displayName: "Recraft V4",
        baseEndpoint: "fal-ai/recraft/v4/pro/text-to-image",
        resolutions: nil, aspectRatios: ["landscape_16_9", "portrait_16_9"],
        supportsImageReference: false,
        resolveEndpoint: { base, _ in base },
        buildFalInput: { prompt, aspectRatio, _, _ in
            var d: [String: Payload] = ["prompt": .string(prompt)]
            if !aspectRatio.isEmpty { d["image_size"] = .string(aspectRatio) }
            return .dict(d)
        }
    )

    static let allModels: [ImageModelConfig] = [
        nanoBananaPro, nanoBanana2, grokImagine, recraftV4,
    ]
}
