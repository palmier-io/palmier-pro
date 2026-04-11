import Foundation
import FalClient

struct VideoModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]

    func buildInput(prompt: String, duration: Int, aspectRatio: String, resolution: String?) -> Payload {
        var dict: [String: Payload] = [
            "prompt": .string(prompt),
            "aspect_ratio": .string(aspectRatio),
        ]

        switch id {
        case "veo3.1":
            dict["duration"] = .string("\(duration)s")
            if let resolution { dict["resolution"] = .string(resolution) }
        case "grok-imagine-video":
            dict["duration"] = .int(duration)
            if let resolution { dict["resolution"] = .string(resolution) }
        default:
            dict["duration"] = .string("\(duration)")
        }

        return .dict(dict)
    }
}

extension VideoModelConfig {
    static let veo31 = VideoModelConfig(
        id: "veo3.1",
        displayName: "Veo 3.1",
        endpoint: "fal-ai/veo3.1/text-to-video",
        durations: [5, 8],
        resolutions: ["720p", "1080p"],
        aspectRatios: ["16:9", "9:16", "1:1"]
    )

    static let klingV3 = VideoModelConfig(
        id: "kling-v3",
        displayName: "Kling V3",
        endpoint: "fal-ai/kling-video/v3/pro/text-to-video",
        durations: [5, 10],
        resolutions: nil,
        aspectRatios: ["16:9", "9:16", "1:1"]
    )

    static let grokImagineVideo = VideoModelConfig(
        id: "grok-imagine-video",
        displayName: "Grok Imagine Video",
        endpoint: "xai/grok-imagine-video/text-to-video",
        durations: [6, 8, 10, 12, 15],
        resolutions: ["480p", "720p"],
        aspectRatios: ["16:9", "9:16"]
    )

    static let allModels: [VideoModelConfig] = [veo31, klingV3, grokImagineVideo]
}
