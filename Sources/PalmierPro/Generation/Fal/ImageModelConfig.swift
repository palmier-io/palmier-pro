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
    let maxImages: Int
    /// USD per image, keyed by the dimension the model varies on quality/resolution
    let pricePerImage: [String: Double]
    let resolveEndpoint: @Sendable (_ base: String, _ imageURLs: [String]) -> String
    let buildFalInput: @Sendable (_ prompt: String, _ aspectRatio: String, _ resolution: String?, _ quality: String?, _ imageURLs: [String], _ numImages: Int) -> Payload

    init(
        id: String, displayName: String, baseEndpoint: String,
        resolutions: [String]? = nil, aspectRatios: [String],
        qualities: [String]? = nil,
        supportsImageReference: Bool,
        maxImages: Int = 1,
        pricePerImage: [String: Double] = [:],
        resolveEndpoint: @escaping @Sendable (String, [String]) -> String,
        buildFalInput: @escaping @Sendable (String, String, String?, String?, [String], Int) -> Payload
    ) {
        self.id = id; self.displayName = displayName; self.baseEndpoint = baseEndpoint
        self.resolutions = resolutions; self.aspectRatios = aspectRatios
        self.qualities = qualities
        self.supportsImageReference = supportsImageReference
        self.maxImages = max(1, min(4, maxImages))
        self.pricePerImage = pricePerImage
        self.resolveEndpoint = resolveEndpoint; self.buildFalInput = buildFalInput
    }

    func resolvedEndpoint(imageURLs: [String]) -> String {
        resolveEndpoint(baseEndpoint, imageURLs)
    }

    func buildInput(prompt: String, aspectRatio: String, resolution: String?, quality: String? = nil, imageURLs: [String] = [], numImages: Int = 1) -> Payload {
        buildFalInput(prompt, aspectRatio, resolution, quality, imageURLs, numImages)
    }

    func validate(aspectRatio: String, resolution: String?, quality: String?, imageRefCount: Int, numImages: Int) -> String? {
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
        }
        if let allowed = qualities, let q = quality, !q.isEmpty, !allowed.contains(q) {
            return unsupportedValue(model: displayName, field: "quality", value: q, allowed: allowed)
        }
        if imageRefCount > 0, !supportsImageReference {
            return "\(displayName) does not accept reference images."
        }
        if numImages < 1 || numImages > maxImages {
            return "\(displayName) supports 1…\(maxImages) image\(maxImages == 1 ? "" : "s") per request (got \(numImages))."
        }
        return nil
    }
}

// MARK: - Shared builders

private func editEndpoint(_ base: String, _ imageURLs: [String]) -> String {
    imageURLs.isEmpty ? base : "\(base)/edit"
}

private func standardInput(prompt: String, aspectRatio: String, resolution: String?, quality: String?, imageURLs: [String], numImages: Int) -> Payload {
    var d: [String: Payload] = ["prompt": .string(prompt), "output_format": .string("jpeg")]
    if !aspectRatio.isEmpty { d["aspect_ratio"] = .string(aspectRatio) }
    if let resolution { d["resolution"] = .string(resolution) }
    if !imageURLs.isEmpty { d["image_urls"] = .array(imageURLs.map { .string($0) }) }
    if numImages > 1 { d["num_images"] = .int(numImages) }
    return .dict(d)
}

// MARK: - Models

extension ImageModelConfig {
    static let nanoBananaPro = ImageModelConfig(
        id: "nano-banana-pro", displayName: "Nano Banana Pro",
        baseEndpoint: "fal-ai/nano-banana-pro",
        resolutions: ["2K", "4K"], aspectRatios: ["auto", "21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"],
        supportsImageReference: true,
        maxImages: 4,
        pricePerImage: ["2K": 0.15, "4K": 0.30],
        resolveEndpoint: editEndpoint, buildFalInput: standardInput
    )

    static let nanoBanana2 = ImageModelConfig(
        id: "nano-banana-2", displayName: "Nano Banana 2",
        baseEndpoint: "fal-ai/nano-banana-2",
        resolutions: ["2K", "4K"], aspectRatios: ["auto", "21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16", "4:1", "1:4", "8:1", "1:8"],
        supportsImageReference: true,
        maxImages: 4,
        pricePerImage: ["2K": 0.12, "4K": 0.16],
        resolveEndpoint: editEndpoint, buildFalInput: standardInput
    )

    static let grokImagine = ImageModelConfig(
        id: "grok-imagine", displayName: "Grok Imagine",
        baseEndpoint: "xai/grok-imagine-image",
        resolutions: nil, aspectRatios: ["2:1", "20:9", "19.5:9", "16:9", "4:3", "3:2", "1:1", "2:3", "3:4", "9:16", "9:19.5", "9:20", "1:2"],
        supportsImageReference: true,
        maxImages: 4,
        pricePerImage: ["": 0.02],
        resolveEndpoint: editEndpoint,
        buildFalInput: { prompt, aspectRatio, _, _, imageURLs, numImages in
            var d: [String: Payload] = ["prompt": .string(prompt)]
            if !imageURLs.isEmpty {
                d["image_urls"] = .array(imageURLs.map { .string($0) })
            } else if !aspectRatio.isEmpty {
                d["aspect_ratio"] = .string(aspectRatio)
            }
            if numImages > 1 { d["num_images"] = .int(numImages) }
            return .dict(d)
        }
    )

    static let recraftV4 = ImageModelConfig(
        id: "recraft-v4", displayName: "Recraft V4",
        baseEndpoint: "fal-ai/recraft/v4/pro/text-to-image",
        resolutions: nil, aspectRatios: ["square_hd", "square", "portrait_4_3", "portrait_16_9", "landscape_4_3", "landscape_16_9"],
        supportsImageReference: false,
        maxImages: 4,
        pricePerImage: ["": 0.25],
        resolveEndpoint: { base, _ in base },
        buildFalInput: { prompt, aspectRatio, _, _, _, numImages in
            var d: [String: Payload] = ["prompt": .string(prompt)]
            if !aspectRatio.isEmpty { d["image_size"] = .string(aspectRatio) }
            if numImages > 1 { d["num_images"] = .int(numImages) }
            return .dict(d)
        }
    )

    static let gptImage2 = ImageModelConfig(
        id: "gpt-image-2", displayName: "GPT Image 2",
        baseEndpoint: "openai/gpt-image-2",
        resolutions: ["1024x768", "1024x1024", "1024x1536", "1920x1080", "2560x1440", "3840x2160"],
        aspectRatios: [],
        qualities: ["low", "medium", "high"],
        supportsImageReference: true,
        pricePerImage: [
            "1024x768|low":   0.01, "1024x768|medium":   0.04, "1024x768|high":   0.15,
            "1024x1024|low":  0.01, "1024x1024|medium":  0.06, "1024x1024|high":  0.22,
            "1024x1536|low":  0.01, "1024x1536|medium":  0.05, "1024x1536|high":  0.17,
            "1920x1080|low":  0.01, "1920x1080|medium":  0.04, "1920x1080|high":  0.16,
            "2560x1440|low":  0.01, "2560x1440|medium":  0.06, "2560x1440|high":  0.23,
            "3840x2160|low":  0.02, "3840x2160|medium":  0.11, "3840x2160|high":  0.41,
        ],
        resolveEndpoint: editEndpoint,
        buildFalInput: { prompt, _, resolution, quality, imageURLs, _ in
            var d: [String: Payload] = [
                "prompt": .string(prompt),
                "output_format": .string("jpeg"),
            ]
            if let resolution, let (w, h) = Self.parseWxH(resolution) {
                d["image_size"] = .dict(["width": .int(w), "height": .int(h)])
            }
            if let quality, !quality.isEmpty { d["quality"] = .string(quality) }
            if !imageURLs.isEmpty { d["image_urls"] = .array(imageURLs.map { .string($0) }) }
            return .dict(d)
        }
    )

    /// Parse a "WxH" resolution label (e.g. "1920x1080") into pixel dims.
    static func parseWxH(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    /// Human-readable label for a resolution ID.
    static func resolutionDisplayLabel(_ id: String) -> String {
        guard let (w, h) = parseWxH(id) else { return id }
        if w == h { return "Square" }
        let orientation = w > h ? "Landscape" : "Portrait"
        // Name by the larger edge when it's a recognizable video tier.
        let longEdge = max(w, h)
        let tier: String
        switch longEdge {
        case 3840:        tier = "4K"
        case 2560:        tier = "2K"
        case 1920:        tier = "1080p"
        case 1024, 1536:  tier = ""
        default:          tier = "\(longEdge)p"
        }
        return tier.isEmpty ? orientation : "\(orientation) \(tier)"
    }

    static let allModels: [ImageModelConfig] = [
        nanoBananaPro, nanoBanana2, gptImage2, grokImagine, recraftV4,
    ]
}
