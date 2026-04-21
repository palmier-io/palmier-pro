import Foundation
import FalClient

struct UpscaleModelConfig: Identifiable, Sendable {
    let id: String
    let displayName: String
    let speed: String
    let endpoint: String
    let pricePerSecond: Double
    let p75DurationSeconds: Int
    let supportedTypes: Set<ClipType>
    let buildFalInput: @Sendable (_ sourceURL: String) -> Payload
}

extension UpscaleModelConfig {
    // MARK: Video upscalers

    static let bytedance = UpscaleModelConfig(
        id: "bytedance-upscaler",
        displayName: "Bytedance Upscaler",
        speed: "Fast",
        endpoint: "fal-ai/bytedance-upscaler/upscale/video",
        pricePerSecond: 0.0288,
        p75DurationSeconds: 130,
        supportedTypes: [.video],
        buildFalInput: { source in
            .dict([
                "video_url": .string(source),
                "target_resolution": .string("4k"),
            ])
        }
    )

    static let seedvr = UpscaleModelConfig(
        id: "seedvr-upscaler",
        displayName: "SeedVR2",
        speed: "Medium",
        endpoint: "fal-ai/seedvr/upscale/video",
        pricePerSecond: 0.062,
        p75DurationSeconds: 691,
        supportedTypes: [.video],
        buildFalInput: { source in
            .dict([
                "video_url": .string(source),
                "upscale_mode": .string("target"),
                "target_resolution": .string("2160p"),
            ])
        }
    )

    static let topaz = UpscaleModelConfig(
        id: "topaz-upscaler",
        displayName: "Topaz Upscale",
        speed: "Slow",
        endpoint: "fal-ai/topaz/upscale/video",
        pricePerSecond: 0.08,
        p75DurationSeconds: 65,
        supportedTypes: [.video],
        buildFalInput: { source in
            .dict([
                "video_url": .string(source),
                "upscale_factor": .int(2),
            ])
        }
    )

    // MARK: Image upscalers

    static let seedvrImage = UpscaleModelConfig(
        id: "seedvr-image-upscaler",
        displayName: "SeedVR2",
        speed: "Fast",
        endpoint: "fal-ai/seedvr/upscale/image",
        pricePerSecond: 0.04,
        p75DurationSeconds: 19,
        supportedTypes: [.image],
        buildFalInput: { source in
            .dict([
                "image_url": .string(source),
                "upscale_mode": .string("target"),
                "target_resolution": .string("2160p"),
            ])
        }
    )

    static let topazImage = UpscaleModelConfig(
        id: "topaz-image-upscaler",
        displayName: "Topaz Upscale",
        speed: "Medium",
        endpoint: "fal-ai/topaz/upscale/image",
        pricePerSecond: 0.08,
        p75DurationSeconds: 24,
        supportedTypes: [.image],
        buildFalInput: { source in
            .dict([
                "image_url": .string(source),
                "upscale_factor": .int(2),
            ])
        }
    )

    static let allModels: [UpscaleModelConfig] = [
        bytedance, seedvr, topaz,
        seedvrImage, topazImage,
    ]

    static var allIds: Set<String> { Set(allModels.map(\.id)) }

    static func models(for type: ClipType) -> [UpscaleModelConfig] {
        allModels.filter { $0.supportedTypes.contains(type) }
    }
}
