import Foundation

enum CostEstimator {

    static func videoCost(
        model: VideoModelConfig,
        durationSeconds: Int,
        resolution: String?,
        generateAudio: Bool
    ) -> Int? {
        guard !model.creditsPerSecond.isEmpty, durationSeconds > 0 else { return nil }
        guard var rate = resolvedRate(model.creditsPerSecond, key: resolution) else { return nil }
        if !generateAudio, let discount = model.audioDiscount(for: resolution) {
            rate *= discount
        }
        return ceilCredits(rate * Double(durationSeconds))
    }

    static func imageCost(
        model: ImageModelConfig,
        resolution: String?,
        quality: String?,
        numImages: Int = 1
    ) -> Int? {
        guard !model.creditsPerImage.isEmpty else { return nil }
        let count = Double(max(1, numImages))
        // 2D matrix lookup first (e.g. GPT Image 2 varies on both axes).
        if let r = resolution, let q = quality, let price = model.creditsPerImage["\(r)|\(q)"] {
            return ceilCredits(price * count)
        }
        // Quality-only lookup when the model varies on quality but not resolution.
        if model.qualities != nil, let q = quality, let price = model.creditsPerImage[q] {
            return ceilCredits(price * count)
        }
        guard let rate = resolvedRate(model.creditsPerImage, key: resolution) else { return nil }
        return ceilCredits(rate * count)
    }

    static func audioCost(
        model: AudioModelConfig,
        prompt: String,
        durationSeconds: Int?
    ) -> Int? {
        switch model.pricing {
        case .perThousandChars(let rate):
            let chars = prompt.count
            guard chars > 0 else { return nil }
            return ceilCredits(rate * (Double(chars) / 1000.0))
        case .perSecond(let rate):
            guard let secs = durationSeconds, secs > 0 else { return nil }
            return ceilCredits(rate * Double(secs))
        case .flat(let price):
            return ceilCredits(price)
        case .unknown:
            return nil
        }
    }

    static func upscaleCost(model: UpscaleModelConfig, durationSeconds: Int) -> Int? {
        let d = max(1, durationSeconds)
        return ceilCredits(model.creditsPerSecond * Double(d))
    }

    static func estimatedTranscriptionCost(durationSeconds: Double) -> Int? {
        guard durationSeconds > 0 else { return nil }
        return ceilCredits(25.0 * durationSeconds / 3600.0)
    }

    /// Recompute cost from a stored `GenerationInput`. Used on rerun.
    @MainActor
    static func cost(for genInput: GenerationInput) -> Int? {
        switch ModelRegistry.byId[genInput.model] {
        case .video(let m):
            return videoCost(
                model: m,
                durationSeconds: genInput.duration,
                resolution: genInput.resolution,
                generateAudio: genInput.generateAudio ?? true
            )
        case .image(let m):
            return imageCost(
                model: m,
                resolution: genInput.resolution,
                quality: genInput.quality,
                numImages: genInput.numImages ?? 1
            )
        case .audio(let m):
            let duration = (m.durations != nil || m.acceptsSourceMedia) ? genInput.duration : nil
            return audioCost(model: m, prompt: genInput.prompt, durationSeconds: duration)
        case .upscale(let m):
            return upscaleCost(model: m, durationSeconds: genInput.duration)
        case .none:
            return nil
        }
    }

    static func format(_ credits: Int?) -> String {
        guard let credits else { return "—" }
        if credits <= 0 { return "0 credits" }
        if credits == 1 { return "1 credit" }
        return "\(credits) credits"
    }

    private static func resolvedRate(_ dict: [String: Double], key: String?) -> Double? {
        if let key, let v = dict[key] { return v }
        return dict[""]
    }

    private static func ceilCredits(_ credits: Double) -> Int {
        guard credits > 0 else { return 0 }
        return Int(credits.rounded(.up))
    }
}
