import Foundation
import FalClient

func unsupportedValue(model displayName: String, field: String, value: String, allowed: [String]) -> String {
    "\(displayName) does not support \(field) '\(value)'. Valid: \(allowed.joined(separator: ", "))."
}

struct VideoModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let baseEndpoint: String
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    /// Combined-duration caps on reference inputs (seconds). Seedance = 15 / 15.
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    /// When true, start/end frames and references are alternate submission modes for the same model
    let framesAndReferencesExclusive: Bool
    /// Noun used in `@`-mention tags for image refs. Kling emits `elements` so uses "Element";
    /// Seedance/Grok use "Image".
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let pricePerSecond: [String: Double]
    /// Audio-off price multiplier per resolution; `""` key is the default.
    let audioDiscountRate: [String: Double]?
    let resolveEndpoint: @Sendable (_ base: String, _ input: VideoGenerationParams) -> String
    let buildFalInput: @Sendable (_ input: VideoGenerationParams) -> Payload

    init(
        id: String, displayName: String, baseEndpoint: String,
        durations: [Int], resolutions: [String]? = nil, aspectRatios: [String],
        supportsFirstFrame: Bool = true, supportsLastFrame: Bool = false,
        maxReferenceImages: Int = 0,
        maxReferenceVideos: Int = 0,
        maxReferenceAudios: Int = 0,
        maxTotalReferences: Int? = nil,
        maxCombinedVideoRefSeconds: Double? = nil,
        maxCombinedAudioRefSeconds: Double? = nil,
        framesAndReferencesExclusive: Bool = false,
        referenceTagNoun: String = "Image",
        requiresSourceVideo: Bool = false,
        pricePerSecond: [String: Double] = [:],
        audioDiscountRate: [String: Double]? = nil,
        resolveEndpoint: @escaping @Sendable (String, VideoGenerationParams) -> String,
        buildFalInput: @escaping @Sendable (VideoGenerationParams) -> Payload
    ) {
        self.id = id; self.displayName = displayName; self.baseEndpoint = baseEndpoint
        self.durations = durations; self.resolutions = resolutions; self.aspectRatios = aspectRatios
        self.supportsFirstFrame = supportsFirstFrame; self.supportsLastFrame = supportsLastFrame
        self.maxReferenceImages = maxReferenceImages
        self.maxReferenceVideos = maxReferenceVideos
        self.maxReferenceAudios = maxReferenceAudios
        self.maxTotalReferences = maxTotalReferences
        self.maxCombinedVideoRefSeconds = maxCombinedVideoRefSeconds
        self.maxCombinedAudioRefSeconds = maxCombinedAudioRefSeconds
        self.framesAndReferencesExclusive = framesAndReferencesExclusive
        self.referenceTagNoun = referenceTagNoun
        self.requiresSourceVideo = requiresSourceVideo
        self.pricePerSecond = pricePerSecond; self.audioDiscountRate = audioDiscountRate
        self.resolveEndpoint = resolveEndpoint; self.buildFalInput = buildFalInput
    }

    var supportsReferences: Bool {
        maxReferenceImages > 0 || maxReferenceVideos > 0 || maxReferenceAudios > 0
    }

    /// Total reference count available across types. Used by agent tool info.
    var maxReferences: Int {
        maxTotalReferences ?? (maxReferenceImages + maxReferenceVideos + maxReferenceAudios)
    }

    func resolvedEndpoint(params: VideoGenerationParams) -> String {
        resolveEndpoint(baseEndpoint, params)
    }

    func buildInput(params: VideoGenerationParams) -> Payload {
        buildFalInput(params)
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

struct VideoGenerationParams: Sendable {
    let prompt: String
    let duration: Int
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
        sourceVideoURL: String? = nil,
        startFrameURL: String? = nil, endFrameURL: String? = nil,
        referenceImageURLs: [String] = [],
        referenceVideoURLs: [String] = [],
        referenceAudioURLs: [String] = [],
        generateAudio: Bool = true
    ) {
        self.prompt = prompt; self.duration = duration
        self.aspectRatio = aspectRatio; self.resolution = resolution
        self.sourceVideoURL = sourceVideoURL
        self.startFrameURL = startFrameURL; self.endFrameURL = endFrameURL
        self.referenceImageURLs = referenceImageURLs
        self.referenceVideoURLs = referenceVideoURLs
        self.referenceAudioURLs = referenceAudioURLs
        self.generateAudio = generateAudio
    }

    var hasAnyReferences: Bool {
        !referenceImageURLs.isEmpty || !referenceVideoURLs.isEmpty || !referenceAudioURLs.isEmpty
    }
}

// MARK: - Shared endpoint resolvers

private func standardVideoEndpoint(_ base: String, _ input: VideoGenerationParams) -> String {
    if input.hasAnyReferences { return "\(base)/reference-to-video" }
    if input.startFrameURL != nil { return "\(base)/image-to-video" }
    return "\(base)/text-to-video"
}

private func frameOnlyEndpoint(_ base: String, _ input: VideoGenerationParams) -> String {
    "\(base)/\(input.startFrameURL != nil ? "image-to-video" : "text-to-video")"
}

// MARK: - Shared input builders

private func buildVeoInput(_ input: VideoGenerationParams) -> Payload {
    var d: [String: Payload] = ["prompt": .string(input.prompt)]
    if let r = input.resolution { d["resolution"] = .string(r) }
    if !input.aspectRatio.isEmpty { d["aspect_ratio"] = .string(input.aspectRatio) }
    d["duration"] = .string("\(input.duration)s")
    d["generate_audio"] = .bool(input.generateAudio)
    if let start = input.startFrameURL, let end = input.endFrameURL {
        d["first_frame_url"] = .string(start)
        d["last_frame_url"] = .string(end)
    } else if let start = input.startFrameURL {
        d["image_url"] = .string(start)
    }
    return .dict(d)
}

private func buildKlingInput(_ input: VideoGenerationParams, startFrameKey: String) -> Payload {
    var d: [String: Payload] = ["prompt": .string(input.prompt)]
    if !input.aspectRatio.isEmpty && input.startFrameURL == nil {
        d["aspect_ratio"] = .string(input.aspectRatio)
    }
    d["generate_audio"] = .bool(input.generateAudio)
    d["duration"] = .string("\(input.duration)")
    if !input.referenceImageURLs.isEmpty {
        d["elements"] = .array(input.referenceImageURLs.map { url in
            .dict(["frontal_image_url": .string(url), "reference_image_urls": .array([.string(url)])])
        })
        if let s = input.startFrameURL { d[startFrameKey] = .string(s) }
        if let e = input.endFrameURL { d["end_image_url"] = .string(e) }
    } else {
        if let s = input.startFrameURL { d["image_url"] = .string(s) }
        if let e = input.endFrameURL { d["end_image_url"] = .string(e) }
    }
    return .dict(d)
}

private func buildSeedanceInput(_ input: VideoGenerationParams) -> Payload {
    var d: [String: Payload] = ["prompt": .string(input.prompt)]
    if input.hasAnyReferences {
        if !input.referenceImageURLs.isEmpty {
            d["image_urls"] = .array(input.referenceImageURLs.map { .string($0) })
        }
        if !input.referenceVideoURLs.isEmpty {
            d["video_urls"] = .array(input.referenceVideoURLs.map { .string($0) })
        }
        if !input.referenceAudioURLs.isEmpty {
            d["audio_urls"] = .array(input.referenceAudioURLs.map { .string($0) })
        }
    } else {
        if let s = input.startFrameURL { d["image_url"] = .string(s) }
        if let e = input.endFrameURL { d["end_image_url"] = .string(e) }
    }
    if let r = input.resolution { d["resolution"] = .string(r) }
    if !input.aspectRatio.isEmpty { d["aspect_ratio"] = .string(input.aspectRatio) }
    d["duration"] = .string("\(input.duration)")
    d["generate_audio"] = .bool(input.generateAudio)
    return .dict(d)
}

// MARK: - Models

extension VideoModelConfig {

    // MARK: Veo 3.1

    private static func veo(
        _ variant: String?, id: String, displayName: String,
        resolutions: [String], pricePerSecond: [String: Double]
    ) -> VideoModelConfig {
        VideoModelConfig(
            id: id, displayName: displayName, baseEndpoint: "fal-ai/veo3.1",
            durations: [4, 6, 8], resolutions: resolutions,
            aspectRatios: ["16:9", "9:16", "1:1"],
            supportsLastFrame: true,
            pricePerSecond: pricePerSecond,
            audioDiscountRate: ["": 2.0 / 3.0],
            resolveEndpoint: { base, input in
                let prefix = variant.map { "\(base)/\($0)" } ?? base
                if input.startFrameURL != nil && input.endFrameURL != nil {
                    return "\(prefix)/first-last-frame-to-video"
                }
                if input.startFrameURL != nil { return "\(prefix)/image-to-video" }
                return variant != nil ? prefix : "\(base)"
            },
            buildFalInput: buildVeoInput
        )
    }

    static let veo31     = veo(nil,    id: "veo3.1",      displayName: "Veo 3.1",      resolutions: ["720p", "1080p", "4k"], pricePerSecond: ["720p": 0.40, "1080p": 0.40, "4k": 0.60])
    static let veo31Fast = veo("fast", id: "veo3.1-fast", displayName: "Veo 3.1 Fast", resolutions: ["720p", "1080p", "4k"], pricePerSecond: ["720p": 0.15, "1080p": 0.15, "4k": 0.35])
    static let veo31Lite = veo("lite", id: "veo3.1-lite", displayName: "Veo 3.1 Lite", resolutions: ["720p", "1080p"],        pricePerSecond: ["720p": 0.05, "1080p": 0.08])

    // MARK: Kling

    /// `proStartFrameKey`/`fourKStartFrameKey` differ between V3 and O3 and even flip between
    /// tiers — both fal schemas need to be matched exactly.
    private static func klingProOr4k(
        id: String, displayName: String, baseEndpoint: String,
        maxReferenceImages: Int,
        pricePerSecond: [String: Double],
        audioDiscountRate: [String: Double],
        proResolver: @escaping @Sendable (String, VideoGenerationParams) -> String,
        proStartFrameKey: String, fourKStartFrameKey: String
    ) -> VideoModelConfig {
        VideoModelConfig(
            id: id, displayName: displayName, baseEndpoint: baseEndpoint,
            durations: Array(4...15),
            resolutions: ["1080p", "4k"],
            aspectRatios: ["16:9", "9:16"],
            supportsLastFrame: true,
            maxReferenceImages: maxReferenceImages,
            referenceTagNoun: "Element",
            pricePerSecond: pricePerSecond,
            audioDiscountRate: audioDiscountRate,
            resolveEndpoint: { base, input in
                if input.resolution == "4k" {
                    return frameOnlyEndpoint("\(base)/4k", input)
                }
                return proResolver("\(base)/pro", input)
            },
            buildFalInput: { input in
                let key = input.resolution == "4k" ? fourKStartFrameKey : proStartFrameKey
                return buildKlingInput(input, startFrameKey: key)
            }
        )
    }

    static let klingV3 = klingProOr4k(
        id: "kling-v3", displayName: "Kling V3",
        baseEndpoint: "fal-ai/kling-video/v3",
        maxReferenceImages: 3,
        pricePerSecond: ["1080p": 0.168, "4k": 0.42],
        audioDiscountRate: ["1080p": 2.0 / 3.0],
        proResolver: frameOnlyEndpoint,
        proStartFrameKey: "image_url", fourKStartFrameKey: "start_image_url"
    )

    static let klingO3 = klingProOr4k(
        id: "kling-o3", displayName: "Kling O3",
        baseEndpoint: "fal-ai/kling-video/o3",
        maxReferenceImages: 7,
        pricePerSecond: ["1080p": 0.14, "4k": 0.42],
        audioDiscountRate: ["1080p": 0.8],
        proResolver: standardVideoEndpoint,
        proStartFrameKey: "start_image_url", fourKStartFrameKey: "image_url"
    )

    // MARK: Seedance

    private static func seedance(
        _ variant: String?, id: String, displayName: String,
        resolutions: [String], pricePerSecond: [String: Double]
    ) -> VideoModelConfig {
        VideoModelConfig(
            id: id, displayName: displayName, baseEndpoint: "bytedance/seedance-2.0",
            durations: Array(4...15), resolutions: resolutions,
            aspectRatios: ["16:9", "9:16", "1:1"],
            supportsLastFrame: true,
            maxReferenceImages: 9,
            maxReferenceVideos: 3,
            maxReferenceAudios: 3,
            maxTotalReferences: 12,
            maxCombinedVideoRefSeconds: 15,
            maxCombinedAudioRefSeconds: 15,
            framesAndReferencesExclusive: true,
            pricePerSecond: pricePerSecond,
            resolveEndpoint: { base, input in
                let prefix = variant.map { "\(base)/\($0)" } ?? base
                return standardVideoEndpoint(prefix, input)
            },
            buildFalInput: buildSeedanceInput
        )
    }

    static let seedance2     = seedance(nil,    id: "seedance-2",      displayName: "Seedance 2",      resolutions: ["480p", "720p", "1080p"], pricePerSecond: ["480p": 0.1345, "720p": 0.3024, "1080p": 0.68])
    static let seedance2Fast = seedance("fast", id: "seedance-2-fast", displayName: "Seedance 2 Fast", resolutions: ["480p", "720p"],           pricePerSecond: ["480p": 0.0843, "720p": 0.2427])

    // MARK: Grok

    static let grokImagineVideo = VideoModelConfig(
        id: "grok-imagine-video", displayName: "Grok Imagine Video",
        baseEndpoint: "xai/grok-imagine-video",
        durations: Array(6...15), resolutions: ["480p", "720p"],
        aspectRatios: ["16:9", "9:16"],
        maxReferenceImages: 7,
        framesAndReferencesExclusive: true,
        pricePerSecond: ["480p": 0.05, "720p": 0.07],
        resolveEndpoint: { base, input in
            if input.startFrameURL != nil { return "\(base)/image-to-video" }
            return standardVideoEndpoint(base, input)
        },
        buildFalInput: { input in
            var d: [String: Payload] = ["prompt": .string(input.prompt)]
            if let s = input.startFrameURL {
                d["image_url"] = .string(s)
            } else if !input.referenceImageURLs.isEmpty {
                d["reference_image_urls"] = .array(input.referenceImageURLs.map { .string($0) })
            }
            if let r = input.resolution { d["resolution"] = .string(r) }
            if !input.aspectRatio.isEmpty { d["aspect_ratio"] = .string(input.aspectRatio) }
            d["duration"] = .int(input.duration)
            return .dict(d)
        }
    )

    // MARK: Edit models (video-to-video)

    static let klingO3Edit = VideoModelConfig(
        id: "kling-o3-edit", displayName: "Kling O3 Edit",
        baseEndpoint: "fal-ai/kling-video/o3/pro/video-to-video/edit",
        durations: [], resolutions: nil, aspectRatios: [],
        supportsFirstFrame: false, supportsLastFrame: false,
        requiresSourceVideo: true,
        pricePerSecond: ["": 0.168],
        resolveEndpoint: { base, _ in base },
        buildFalInput: { input in
            var d: [String: Payload] = ["prompt": .string(input.prompt)]
            if let src = input.sourceVideoURL { d["video_url"] = .string(src) }
            return .dict(d)
        }
    )

    static let klingV3MotionControl = VideoModelConfig(
        id: "kling-v3-motion-control", displayName: "Kling V3 Motion Control",
        baseEndpoint: "fal-ai/kling-video/v3/pro/motion-control",
        durations: [], resolutions: nil, aspectRatios: [],
        supportsFirstFrame: false, supportsLastFrame: false,
        maxReferenceImages: 1,
        requiresSourceVideo: true,
        pricePerSecond: ["": 0.168],
        resolveEndpoint: { base, _ in base },
        buildFalInput: { input in
            var d: [String: Payload] = ["character_orientation": .string("video")]
            if let src = input.sourceVideoURL { d["video_url"] = .string(src) }
            if let img = input.referenceImageURLs.first { d["image_url"] = .string(img) }
            if !input.prompt.isEmpty { d["prompt"] = .string(input.prompt) }
            return .dict(d)
        }
    )

    static let allModels: [VideoModelConfig] = [
        seedance2, seedance2Fast,
        klingO3, klingV3,
        veo31Fast, veo31, veo31Lite,
        grokImagineVideo,
        klingO3Edit, klingV3MotionControl,
    ]
}
