import Foundation

/// USD cost estimator for fal generations
enum CostEstimator {

    // MARK: - Video

    static func videoCost(
        model: VideoModelConfig,
        durationSeconds: Int,
        resolution: String?,
        generateAudio: Bool
    ) -> Double? {
        guard !model.pricePerSecond.isEmpty, durationSeconds > 0 else { return nil }
        guard var rate = resolvedRate(model.pricePerSecond, key: resolution) else { return nil }
        if !generateAudio, let discount = model.audioDiscountRate {
            rate *= discount
        }
        return rate * Double(durationSeconds)
    }

    // MARK: - Image

    static func imageCost(
        model: ImageModelConfig,
        resolution: String?,
        quality: String?,
        numImages: Int = 1
    ) -> Double? {
        guard !model.pricePerImage.isEmpty else { return nil }
        let count = Double(max(1, numImages))
        // 2D matrix lookup first (e.g. GPT Image 2 varies on both axes).
        if let r = resolution, let q = quality, let price = model.pricePerImage["\(r)|\(q)"] {
            return price * count
        }
        // Quality-only lookup when the model varies on quality but not resolution.
        if model.qualities != nil, let q = quality, let price = model.pricePerImage[q] {
            return price * count
        }
        guard let rate = resolvedRate(model.pricePerImage, key: resolution) else { return nil }
        return rate * count
    }

    // MARK: - Audio

    static func audioCost(
        model: AudioModelConfig,
        prompt: String,
        durationSeconds: Int?
    ) -> Double? {
        switch model.pricing {
        case .perThousandChars(let rate):
            let chars = prompt.count
            guard chars > 0 else { return nil }
            return rate * (Double(chars) / 1000.0)
        case .perSecond(let rate):
            guard let secs = durationSeconds, secs > 0 else { return nil }
            return rate * Double(secs)
        case .flat(let price):
            return price
        case .unknown:
            return nil
        }
    }

    // MARK: - Upscale

    static func upscaleCost(model: UpscaleModelConfig, durationSeconds: Int) -> Double? {
        let d = max(1, durationSeconds)
        return model.pricePerSecond * Double(d)
    }

    /// Recompute cost from a stored `GenerationInput`. Used on rerun
    @MainActor
    static func cost(for genInput: GenerationInput) -> Double? {
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
            let duration = m.durations != nil ? genInput.duration : nil
            return audioCost(model: m, prompt: genInput.prompt, durationSeconds: duration)
        case .upscale(let m):
            return upscaleCost(model: m, durationSeconds: genInput.duration)
        case .none:
            return nil
        }
    }

    // MARK: - Formatting

    static func format(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        if cost <= 0 { return "$0.00" }
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }

    // MARK: - Private

    private static func resolvedRate(_ dict: [String: Double], key: String?) -> Double? {
        if let key, let v = dict[key] { return v }
        return dict[""]
    }
}
