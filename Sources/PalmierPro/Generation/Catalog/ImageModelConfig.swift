import Foundation

struct ImageGenerationParams: Encodable, Sendable {
    let prompt: String
    let aspectRatio: String
    let resolution: String?
    let quality: String?
    let imageURLs: [String]
    let numImages: Int

    enum CodingKeys: String, CodingKey {
        case kind, prompt, aspectRatio, resolution, quality, imageURLs, numImages
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("image", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(quality, forKey: .quality)
        if !imageURLs.isEmpty { try c.encode(imageURLs, forKey: .imageURLs) }
        try c.encode(numImages, forKey: .numImages)
    }
}

struct ImageModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [ImageModelConfig] { ModelCatalog.shared.image }

    @MainActor
    static var nanoBananaPro: ImageModelConfig? {
        allModels.first(where: { $0.id == "nano-banana-pro" })
    }

    let entry: CatalogEntry
    let caps: ImageCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var paidOnly: Bool { entry.paidOnly }
    var creditsPerImage: [String: Double] { entry.creditsPerImage ?? [:] }

    var resolutions: [String]? { caps.resolutions }
    var aspectRatios: [String] { caps.aspectRatios }
    var qualities: [String]? { caps.qualities }
    var supportsImageReference: Bool { caps.supportsImageReference }
    var maxImages: Int { max(1, min(4, caps.maxImages)) }

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

    /// Human-readable label for image aspect/image-size API enum values.
    static func aspectRatioDisplayLabel(_ id: String) -> String {
        guard !id.contains(":") else { return id }
        var parts = id.split(separator: "_").map(String.init)
        guard !parts.isEmpty else { return id }

        if parts.count >= 2,
           let width = Int(parts[parts.count - 2]),
           let height = Int(parts[parts.count - 1]) {
            parts.removeLast(2)
            parts.append("\(width):\(height)")
        }

        return parts.map(aspectRatioDisplayToken).joined(separator: " ")
    }

    private static func aspectRatioDisplayToken(_ token: String) -> String {
        let lower = token.lowercased()
        return switch lower {
        case "hd", "uhd", "1k", "2k", "4k", "8k": lower.uppercased()
        default: lower.capitalized
        }
    }
}
