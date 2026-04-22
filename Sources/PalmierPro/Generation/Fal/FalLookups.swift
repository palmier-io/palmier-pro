import Foundation
import FalClient

/// Output URL extractors keyed to each fal response shape. Returns every URL
/// the response carries — most models yield one, image models with
/// `num_images > 1` yield several.
enum FalResponsePaths {
    static let video: @Sendable (Payload) -> [String] = { wrapSingle($0["video"]["url"].stringValue) }
    static let generatedImage: @Sendable (Payload) -> [String] = { payload in
        guard case .array(let items) = payload["images"] else { return [] }
        return items.compactMap { $0["url"].stringValue }
    }
    static let upscaledImage: @Sendable (Payload) -> [String] = { wrapSingle($0["image"]["url"].stringValue) }
    static let audio: @Sendable (Payload) -> [String] = { wrapSingle($0["audio"]["url"].stringValue) }

    private static func wrapSingle(_ url: String?) -> [String] {
        guard let url else { return [] }
        return [url]
    }
}

extension FileType {
    static func inferred(from url: URL) -> FileType {
        switch url.pathExtension.lowercased() {
        case "png": .imagePng
        case "webp": .imageWebp
        case "gif": .imageGif
        case "jpg", "jpeg": .imageJpeg
        case "mp4", "m4v", "mov": .videoMp4
        case "mp3": .audioMp3
        case "wav": .audioWav
        default: .applicationStream
        }
    }
}

/// Lookups across the fal model registries (Video/Image/Audio/Upscale).
@MainActor
enum ModelRegistry {
    enum Model {
        case video(VideoModelConfig)
        case image(ImageModelConfig)
        case audio(AudioModelConfig)
        case upscale(UpscaleModelConfig)

        var displayName: String {
            switch self {
            case .video(let m):   m.displayName
            case .image(let m):   m.displayName
            case .audio(let m):   m.displayName
            case .upscale(let m): m.displayName
            }
        }
    }

    static let byId: [String: Model] = {
        var d: [String: Model] = [:]
        for m in VideoModelConfig.allModels   { d[m.id] = .video(m) }
        for m in ImageModelConfig.allModels   { d[m.id] = .image(m) }
        for m in AudioModelConfig.allModels   { d[m.id] = .audio(m) }
        for m in UpscaleModelConfig.allModels { d[m.id] = .upscale(m) }
        return d
    }()

    static func displayName(for modelId: String) -> String {
        byId[modelId]?.displayName ?? modelId
    }

    static func exists(id: String) -> Bool {
        byId[id] != nil
    }
}
