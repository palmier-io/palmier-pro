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
        durationSeconds: Int?,
        input: AudioModelConfig.Input? = nil
    ) -> Int? {
        switch model.pricing(for: input) {
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

    static func upscaleCost(
        model: UpscaleModelConfig,
        durationSeconds: Int,
        settings: UpscaleSettings? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        sourceFPS: Double? = nil
    ) -> Int? {
        let d = max(1, durationSeconds)
        let selections = model.defaultSettings.selections.merging(settings?.selections ?? [:]) { _, new in new }
        if let tiers = model.pricing?.megapixelRates {
            guard let width = sourceWidth, let height = sourceHeight else {
                return ceilCredits(model.creditsPerSecond)
            }
            let targetEdge = selections["targetResolution"] == "1080p" ? 1920.0 : 3840.0
            let factor = max(1, targetEdge / Double(max(width, height)))
            let outputMP = Double(width * height) * factor * factor / 1_000_000
            return tiers.first(where: { outputMP <= $0.upTo }).map { ceilCredits($0.credits) }
        }
        let resolution = model.pricing?.sourceResolutionFloor == true
            && max(sourceWidth ?? 0, sourceHeight ?? 0) > 1920
            ? "4k" : selections["targetResolution"]
        var rate = resolution.flatMap { model.pricing?.ratesByResolution?[$0] }
            ?? model.creditsPerSecond
        let fps: String? = if selections["targetFPS"] == "source" {
            sourceFPS.map { String(Int($0.rounded())) }
                ?? (settings == nil ? nil : "60")
        } else {
            selections["targetFPS"]
        }
        if let fps, let multiplier = model.pricing?.fpsMultipliers?[fps] {
            rate *= multiplier
        }
        if let tier = selections["enhancementTier"], let multiplier = model.pricing?.tierMultipliers?[tier] {
            rate *= multiplier
        }
        return ceilCredits(rate * (model.pricing?.mode == .flat ? 1 : Double(d)))
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
            let input = genInput.audioInput.flatMap(AudioModelConfig.Input.init(rawValue:))
            let duration = (m.hasDurationControl || m.acceptsSourceMedia) ? genInput.duration : nil
            return audioCost(
                model: m,
                prompt: genInput.prompt,
                durationSeconds: duration,
                input: input
            )
        case .upscale(let m):
            return upscaleCost(
                model: m,
                durationSeconds: genInput.duration,
                settings: genInput.upscaleSettings,
                sourceWidth: genInput.upscaleSourceWidth,
                sourceHeight: genInput.upscaleSourceHeight,
                sourceFPS: genInput.upscaleSourceFPS
            )
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
