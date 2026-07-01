import Foundation

struct UpscaleGenerationParams: Encodable, Sendable {
    let sourceURL: String
    let durationSeconds: Int

    enum CodingKeys: String, CodingKey { case kind, sourceURL, durationSeconds }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("upscale", forKey: .kind)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(durationSeconds, forKey: .durationSeconds)
    }
}

struct UpscaleModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [UpscaleModelConfig] { ModelCatalog.shared.upscale }

    @MainActor
    static var allIds: Set<String> { Set(allModels.map(\.id)) }

    @MainActor
    static func models(for type: ClipType) -> [UpscaleModelConfig] {
        allModels.filter { $0.supportedTypes.contains(type) }
    }

    let entry: CatalogEntry
    let caps: UpscaleCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var paidOnly: Bool { entry.paidOnly }
    var creditsPerSecond: Double { entry.creditsPerSecondUpscale ?? 0 }

    var speed: String { caps.speed }
    var p75DurationSeconds: Int { caps.p75DurationSeconds }
    var supportedTypes: Set<ClipType> {
        Set(caps.supportedTypes.compactMap(ClipType.init(rawValue:)))
    }
}
