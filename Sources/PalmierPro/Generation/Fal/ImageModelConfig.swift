import Foundation
import FalClient

struct ImageModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let baseEndpoint: String
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let resolveEndpoint: @Sendable (_ base: String, _ imageURLs: [String]) -> String
    let buildFalInput: @Sendable (_ prompt: String, _ aspectRatio: String, _ resolution: String?, _ quality: String?, _ imageURLs: [String]) -> Payload

    init(
        id: String, displayName: String, baseEndpoint: String,
        resolutions: [String]? = nil, aspectRatios: [String],
        qualities: [String]? = nil,
        supportsImageReference: Bool,
        resolveEndpoint: @escaping @Sendable (String, [String]) -> String,
        buildFalInput: @escaping @Sendable (String, String, String?, String?, [String]) -> Payload
    ) {
        self.id = id; self.displayName = displayName; self.baseEndpoint = baseEndpoint
        self.resolutions = resolutions; self.aspectRatios = aspectRatios
        self.qualities = qualities
        self.supportsImageReference = supportsImageReference
        self.resolveEndpoint = resolveEndpoint; self.buildFalInput = buildFalInput
    }

    func resolvedEndpoint(imageURLs: [String]) -> String {
        resolveEndpoint(baseEndpoint, imageURLs)
    }

    func buildInput(prompt: String, aspectRatio: String, resolution: String?, quality: String? = nil, imageURLs: [String] = []) -> Payload {
        buildFalInput(prompt, aspectRatio, resolution, quality, imageURLs)
    }
}

// MARK: - Shared builders

private func editEndpoint(_ base: String, _ imageURLs: [String]) -> String {
    imageURLs.isEmpty ? base : "\(base)/edit"
}

private func standardInput(prompt: String, aspectRatio: String, resolution: String?, quality: String?, imageURLs: [String]) -> Payload {
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
        buildFalInput: { prompt, aspectRatio, _, _, imageURLs in
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
        buildFalInput: { prompt, aspectRatio, _, _, _ in
            var d: [String: Payload] = ["prompt": .string(prompt)]
            if !aspectRatio.isEmpty { d["image_size"] = .string(aspectRatio) }
            return .dict(d)
        }
    )

    static let gptImage2 = ImageModelConfig(
        id: "gpt-image-2", displayName: "GPT Image 2",
        baseEndpoint: "openai/gpt-image-2",
        resolutions: nil, aspectRatios: ["16:9", "9:16", "1:1"],
        qualities: ["low", "medium", "high"],
        supportsImageReference: true,
        resolveEndpoint: editEndpoint,
        buildFalInput: { prompt, aspectRatio, _, quality, imageURLs in
            var d: [String: Payload] = [
                "prompt": .string(prompt),
                "output_format": .string("jpeg"),
            ]
            let imageSize: String? = switch aspectRatio {
                case "16:9": "landscape_16_9"
                case "9:16": "portrait_16_9"
                case "1:1":  "square_hd"
                default:     nil
            }
            if let imageSize { d["image_size"] = .string(imageSize) }
            if let quality, !quality.isEmpty { d["quality"] = .string(quality) }
            if !imageURLs.isEmpty { d["image_urls"] = .array(imageURLs.map { .string($0) }) }
            return .dict(d)
        }
    )

    static let allModels: [ImageModelConfig] = [
        nanoBananaPro, nanoBanana2, gptImage2, grokImagine, recraftV4,
    ]
}
