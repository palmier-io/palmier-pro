import Foundation

func unsupportedValue(model displayName: String, field: String, value: String, allowed: [String]) -> String {
    "\(displayName) does not support \(field) '\(value)'. Valid: \(allowed.joined(separator: ", "))."
}

struct VideoModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [VideoModelConfig] { ModelCatalog.shared.video }

    @MainActor
    static var edit: VideoModelConfig? {
        allModels.first(where: \.isEdit)
    }

    @MainActor
    static var reframe: VideoModelConfig? {
        allModels.first(where: { $0.id.contains("reframe") })
    }

    @MainActor
    static var lipSync: VideoModelConfig? {
        allModels.first(where: \.isLipSync)
    }

    let entry: CatalogEntry
    let caps: VideoCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var providerName: String? { entry.providerName }
    var paidOnly: Bool { entry.paidOnly }
    var creditsPerSecond: [String: Double] { entry.creditsPerSecond ?? [:] }
    var audioDiscountRate: [String: Double]? { entry.audioDiscountRate }
    var supportsPrompt: Bool { caps.supportsPrompt ?? true }

    var durations: [Int] { caps.durations }
    var resolutions: [String]? { caps.resolutions }
    var aspectRatios: [String] { caps.aspectRatios }
    var supportsFirstFrame: Bool { caps.supportsFirstFrame }
    var supportsLastFrame: Bool { caps.supportsLastFrame }
    var maxReferenceImages: Int { caps.maxReferenceImages }
    var maxReferenceVideos: Int { caps.maxReferenceVideos }
    var maxReferenceAudios: Int { caps.maxReferenceAudios }
    var maxTotalReferences: Int? { caps.maxTotalReferences }
    var maxCombinedVideoRefSeconds: Double? { caps.maxCombinedVideoRefSeconds }
    var maxCombinedAudioRefSeconds: Double? { caps.maxCombinedAudioRefSeconds }
    var framesAndReferencesExclusive: Bool { caps.framesAndReferencesExclusive }
    var referenceTagNoun: String { caps.referenceTagNoun }
    var requiresSourceVideo: Bool { caps.requiresSourceVideo }
    var maxSourceVideoSeconds: Double? { caps.maxSourceVideoSeconds }
    var requiresReferenceImage: Bool { caps.requiresReferenceImage }
    var requiresReferenceAudio: Bool { caps.requiresReferenceAudio ?? false }
    var isEdit: Bool {
        supportsPrompt && requiresSourceVideo && !requiresReferenceImage && !requiresReferenceAudio
    }
    var isLipSync: Bool { !supportsPrompt && requiresSourceVideo && requiresReferenceAudio }

    var supportsReferences: Bool {
        maxReferenceImages > 0 || maxReferenceVideos > 0 || maxReferenceAudios > 0
    }

    var sourceDurationLimitLabel: String? {
        guard let maximum = maxSourceVideoSeconds,
              maximum.isFinite, maximum > 0,
              let seconds = Int(exactly: maximum.rounded()) else { return nil }
        if seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    func validateSourceDuration(_ duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else {
            return "Loading video metadata…"
        }
        guard let maximum = maxSourceVideoSeconds,
              duration > maximum,
              let limit = sourceDurationLimitLabel else { return nil }
        return "\(displayName) supports source videos up to \(limit). Trim the clip to continue."
    }

    func billingDurationSeconds(
        sourceVideoDuration: Double,
        sourceAudioDuration: Double?
    ) -> Int? {
        let seconds = isLipSync ? sourceAudioDuration : sourceVideoDuration
        guard let seconds, seconds.isFinite, seconds > 0,
              let rounded = Int(exactly: seconds.rounded()) else { return nil }
        return max(1, rounded)
    }

    func audioDiscount(for resolution: String?) -> Double? {
        guard let dict = audioDiscountRate else { return nil }
        if let key = resolution, let v = dict[key] { return v }
        return dict[""]
    }

    func validate(duration: Int, aspectRatio: String, resolution: String?) -> String? {
        if !durations.isEmpty, !durations.contains(duration) {
            return unsupportedValue(
                model: displayName, field: "duration",
                value: "\(duration)s", allowed: durations.map { "\($0)s" }
            )
        }
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
        }
        return nil
    }
}

struct VideoGenerationParams: Encodable, Sendable {
    let prompt: String
    let duration: Int
    let sourceVideoDuration: Double?
    let aspectRatio: String
    let resolution: String?
    let sourceVideoURL: String?
    let startFrameURL: String?
    let endFrameURL: String?
    let referenceImageURLs: [String]
    let referenceVideoURLs: [String]
    let referenceAudioURLs: [String]
    let generateAudio: Bool

    init(
        prompt: String, duration: Int, aspectRatio: String, resolution: String?,
        sourceVideoDuration: Double? = nil,
        sourceVideoURL: String? = nil,
        startFrameURL: String? = nil, endFrameURL: String? = nil,
        referenceImageURLs: [String] = [],
        referenceVideoURLs: [String] = [],
        referenceAudioURLs: [String] = [],
        generateAudio: Bool = true
    ) {
        self.prompt = prompt; self.duration = duration; self.sourceVideoDuration = sourceVideoDuration
        self.aspectRatio = aspectRatio; self.resolution = resolution
        self.sourceVideoURL = sourceVideoURL
        self.startFrameURL = startFrameURL; self.endFrameURL = endFrameURL
        self.referenceImageURLs = referenceImageURLs
        self.referenceVideoURLs = referenceVideoURLs
        self.referenceAudioURLs = referenceAudioURLs
        self.generateAudio = generateAudio
    }

    enum CodingKeys: String, CodingKey {
        case kind, prompt, duration, sourceVideoDuration, aspectRatio, resolution, sourceVideoURL
        case startFrameURL, endFrameURL, referenceImageURLs, referenceVideoURLs
        case referenceAudioURLs, generateAudio
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("video", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(sourceVideoDuration, forKey: .sourceVideoDuration)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(sourceVideoURL, forKey: .sourceVideoURL)
        try c.encodeIfPresent(startFrameURL, forKey: .startFrameURL)
        try c.encodeIfPresent(endFrameURL, forKey: .endFrameURL)
        if !referenceImageURLs.isEmpty { try c.encode(referenceImageURLs, forKey: .referenceImageURLs) }
        if !referenceVideoURLs.isEmpty { try c.encode(referenceVideoURLs, forKey: .referenceVideoURLs) }
        if !referenceAudioURLs.isEmpty { try c.encode(referenceAudioURLs, forKey: .referenceAudioURLs) }
        try c.encode(generateAudio, forKey: .generateAudio)
    }
}
