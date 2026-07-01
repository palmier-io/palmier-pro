import Foundation
import Combine
@preconcurrency import ConvexMobile

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)
}

enum ModelRegistry {
    @MainActor static var byId: [String: ModelKind] { ModelCatalog.shared.byId }

    @MainActor static func exists(id: String) -> Bool { byId[id] != nil }


    @MainActor static func displayName(for id: String) -> String {
        switch byId[id] {
        case .video(let m): m.displayName
        case .image(let m): m.displayName
        case .audio(let m): m.displayName
        case .upscale(let m): m.displayName
        case .none: id
        }
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var isLoaded: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var didConfigure = false

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true

        guard let client = AccountService.shared.convex else { return }

        subscription = client
            .subscribe(to: "models:list", yielding: [CatalogEntry].self)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
                        Log.generation.error("ModelCatalog subscription failed: \(err.localizedDescription)")
                        self?.lastError = err.localizedDescription
                    }
                },
                receiveValue: { [weak self] entries in
                    self?.apply(entries)
                }
            )
    }

    private func apply(_ entries: [CatalogEntry]) {
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            switch entry.uiCapabilities {
            case .video(let caps):
                let m = VideoModelConfig(entry: entry, caps: caps)
                newVideo.append(m)
                newById[m.id] = .video(m)
            case .image(let caps):
                let m = ImageModelConfig(entry: entry, caps: caps)
                newImage.append(m)
                newById[m.id] = .image(m)
            case .audio(let caps):
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .upscale(let caps):
                let m = UpscaleModelConfig(entry: entry, caps: caps)
                newUpscale.append(m)
                newById[m.id] = .upscale(m)
            }
        }

        self.video = newVideo
        self.image = newImage
        self.audio = newAudio
        self.upscale = newUpscale
        self.byId = newById
        self.isLoaded = true
        self.lastError = nil
    }
}

struct CatalogEntry: Decodable, Sendable {
    let id: String
    let kind: Kind
    let displayName: String
    let allowedEndpoints: [String]
    let responseShape: ResponseShape
    let uiCapabilities: UICapabilities
    let creditsPerSecond: [String: Double]?
    let audioDiscountRate: [String: Double]?
    let creditsPerImage: [String: Double]?
    let qualities: [String]?
    let audioPricing: AudioPricing?
    let creditsPerSecondUpscale: Double?
    let paidOnly: Bool

    enum Kind: String, Decodable, Sendable { case video, image, audio, upscale }
    enum ResponseShape: String, Decodable, Sendable {
        case video, images, audio, upscaledImage
    }

    enum UICapabilities: Sendable {
        case video(VideoCaps)
        case image(ImageCaps)
        case audio(AudioCaps)
        case upscale(UpscaleCaps)
    }

    enum AudioPricing: Decodable, Sendable {
        case perThousandChars(rate: Double)
        case perSecond(rate: Double)
        case flat(price: Double)

        private enum K: String, CodingKey { case mode, rate, price }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .mode) {
            case "perThousandChars":
                self = .perThousandChars(rate: try c.decode(Double.self, forKey: .rate))
            case "perSecond":
                self = .perSecond(rate: try c.decode(Double.self, forKey: .rate))
            case "flat":
                self = .flat(price: try c.decode(Double.self, forKey: .price))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: c,
                    debugDescription: "Unknown audio pricing mode"
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, allowedEndpoints, responseShape, uiCapabilities
        case creditsPerSecond, audioDiscountRate, creditsPerImage, qualities
        case audioPricing, creditsPerSecondUpscale, paidOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.allowedEndpoints = try c.decode([String].self, forKey: .allowedEndpoints)
        self.responseShape = try c.decode(ResponseShape.self, forKey: .responseShape)
        self.creditsPerSecond = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerSecond)
        self.audioDiscountRate = try c.decodeIfPresent([String: Double].self, forKey: .audioDiscountRate)
        self.creditsPerImage = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerImage)
        self.qualities = try c.decodeIfPresent([String].self, forKey: .qualities)
        self.audioPricing = try c.decodeIfPresent(AudioPricing.self, forKey: .audioPricing)
        self.creditsPerSecondUpscale = try c.decodeIfPresent(Double.self, forKey: .creditsPerSecondUpscale)
        self.paidOnly = try c.decodeIfPresent(Bool.self, forKey: .paidOnly) ?? false
        switch self.kind {
        case .video:
            self.uiCapabilities = .video(try c.decode(VideoCaps.self, forKey: .uiCapabilities))
        case .image:
            self.uiCapabilities = .image(try c.decode(ImageCaps.self, forKey: .uiCapabilities))
        case .audio:
            self.uiCapabilities = .audio(try c.decode(AudioCaps.self, forKey: .uiCapabilities))
        case .upscale:
            self.uiCapabilities = .upscale(try c.decode(UpscaleCaps.self, forKey: .uiCapabilities))
        }
    }
}

struct VideoCaps: Decodable, Sendable {
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let requiresReferenceImage: Bool
}

struct ImageCaps: Decodable, Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int
}

struct AudioCaps: Decodable, Sendable {
    let category: String   // "tts" | "music" | "sfx"
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let minPromptLength: Int
    let inputs: [String]? // "text" | "video"
    let promptLabel: String?
    let minSeconds: Int?
    let maxSeconds: Int?
}

struct UpscaleCaps: Decodable, Sendable {
    let speed: String   // "Fast" | "Medium" | "Slow"
    let p75DurationSeconds: Int
    let supportedTypes: [String]   // "video" | "image"
}
