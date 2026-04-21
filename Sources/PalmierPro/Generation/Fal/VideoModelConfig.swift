import Foundation
import FalClient

struct VideoModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let baseEndpoint: String
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let supportsReferences: Bool
    let maxReferences: Int
    let requiresSourceVideo: Bool
    let resolveEndpoint: @Sendable (_ base: String, _ input: VideoGenerationParams) -> String
    let buildFalInput: @Sendable (_ input: VideoGenerationParams) -> Payload

    init(
        id: String, displayName: String, baseEndpoint: String,
        durations: [Int], resolutions: [String]? = nil, aspectRatios: [String],
        supportsFirstFrame: Bool = true, supportsLastFrame: Bool = false,
        supportsReferences: Bool = false, maxReferences: Int = 0,
        requiresSourceVideo: Bool = false,
        resolveEndpoint: @escaping @Sendable (String, VideoGenerationParams) -> String,
        buildFalInput: @escaping @Sendable (VideoGenerationParams) -> Payload
    ) {
        self.id = id; self.displayName = displayName; self.baseEndpoint = baseEndpoint
        self.durations = durations; self.resolutions = resolutions; self.aspectRatios = aspectRatios
        self.supportsFirstFrame = supportsFirstFrame; self.supportsLastFrame = supportsLastFrame
        self.supportsReferences = supportsReferences; self.maxReferences = maxReferences
        self.requiresSourceVideo = requiresSourceVideo
        self.resolveEndpoint = resolveEndpoint; self.buildFalInput = buildFalInput
    }

    func resolvedEndpoint(params: VideoGenerationParams) -> String {
        resolveEndpoint(baseEndpoint, params)
    }

    func buildInput(params: VideoGenerationParams) -> Payload {
        buildFalInput(params)
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
    let generateAudio: Bool
}

// MARK: - Shared endpoint resolvers

private func standardVideoEndpoint(_ base: String, _ input: VideoGenerationParams) -> String {
    if !input.referenceImageURLs.isEmpty { return "\(base)/reference-to-video" }
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

private func buildKlingInput(startFrameKey: String) -> @Sendable (VideoGenerationParams) -> Payload {
    { input in
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
}

private func buildSeedanceInput(_ input: VideoGenerationParams) -> Payload {
    var d: [String: Payload] = ["prompt": .string(input.prompt)]
    if let s = input.startFrameURL { d["image_url"] = .string(s) }
    if let e = input.endFrameURL { d["end_image_url"] = .string(e) }
    if input.startFrameURL == nil && !input.referenceImageURLs.isEmpty {
        d["image_urls"] = .array(input.referenceImageURLs.map { .string($0) })
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

    private static func veo(_ variant: String?, id: String, displayName: String, resolutions: [String]) -> VideoModelConfig {
        VideoModelConfig(
            id: id, displayName: displayName, baseEndpoint: "fal-ai/veo3.1",
            durations: [4, 6, 8], resolutions: resolutions,
            aspectRatios: ["16:9", "9:16", "1:1"],
            supportsLastFrame: true,
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

    static let veo31     = veo(nil,    id: "veo3.1",      displayName: "Veo 3.1",      resolutions: ["720p", "1080p", "4k"])
    static let veo31Fast = veo("fast", id: "veo3.1-fast", displayName: "Veo 3.1 Fast", resolutions: ["720p", "1080p", "4k"])
    static let veo31Lite = veo("lite", id: "veo3.1-lite", displayName: "Veo 3.1 Lite", resolutions: ["720p", "1080p"])

    // MARK: Kling

    static let klingV3 = VideoModelConfig(
        id: "kling-v3", displayName: "Kling V3",
        baseEndpoint: "fal-ai/kling-video/v3/pro",
        durations: Array(3...15), aspectRatios: ["16:9", "9:16"],
        supportsLastFrame: true, supportsReferences: true, maxReferences: 3,
        resolveEndpoint: frameOnlyEndpoint,
        buildFalInput: buildKlingInput(startFrameKey: "image_url")
    )

    static let klingO3 = VideoModelConfig(
        id: "kling-o3", displayName: "Kling O3",
        baseEndpoint: "fal-ai/kling-video/o3/pro",
        durations: Array(3...15), aspectRatios: ["16:9", "9:16"],
        supportsLastFrame: true, supportsReferences: true, maxReferences: 7,
        resolveEndpoint: standardVideoEndpoint,
        buildFalInput: buildKlingInput(startFrameKey: "start_image_url")
    )

    // MARK: Seedance

    private static func seedance(_ variant: String?, id: String, displayName: String, resolutions: [String]) -> VideoModelConfig {
        VideoModelConfig(
            id: id, displayName: displayName, baseEndpoint: "bytedance/seedance-2.0",
            durations: Array(4...15), resolutions: resolutions,
            aspectRatios: ["16:9", "9:16", "1:1"],
            supportsLastFrame: true, supportsReferences: true, maxReferences: 9,
            resolveEndpoint: { base, input in
                let prefix = variant.map { "\(base)/\($0)" } ?? base
                return standardVideoEndpoint(prefix, input)
            },
            buildFalInput: buildSeedanceInput
        )
    }

    static let seedance2     = seedance(nil,    id: "seedance-2",      displayName: "Seedance 2",      resolutions: ["480p", "720p", "1080p"])
    static let seedance2Fast = seedance("fast", id: "seedance-2-fast", displayName: "Seedance 2 Fast", resolutions: ["480p", "720p"])

    // MARK: Grok

    static let grokImagineVideo = VideoModelConfig(
        id: "grok-imagine-video", displayName: "Grok Imagine Video",
        baseEndpoint: "xai/grok-imagine-video",
        durations: Array(6...15), resolutions: ["480p", "720p"],
        aspectRatios: ["16:9", "9:16"],
        supportsReferences: true, maxReferences: 7,
        resolveEndpoint: { base, input in
            if input.startFrameURL != nil { return "\(base)/image-to-video" }
            return standardVideoEndpoint(base, input)
        },
        buildFalInput: { input in
            let useRefs = input.startFrameURL == nil && !input.referenceImageURLs.isEmpty
            var d: [String: Payload] = ["prompt": .string(input.prompt)]
            if let s = input.startFrameURL { d["image_url"] = .string(s) }
            if useRefs { d["reference_image_urls"] = .array(input.referenceImageURLs.map { .string($0) }) }
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
        supportsReferences: false, maxReferences: 0,
        requiresSourceVideo: true,
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
        supportsReferences: true, maxReferences: 1,
        requiresSourceVideo: true,
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
