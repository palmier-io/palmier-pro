import Foundation

struct UpscaleSettings: Codable, Sendable, Equatable {
    var selections: [String: String] = [:]
    var numbers: [String: Double] = [:]
    var toggles: [String: Bool] = [:]
}

struct UpscaleGenerationParams: Encodable, Sendable {
    let sourceURL: String
    let durationSeconds: Int
    let sourceWidth: Int?
    let sourceHeight: Int?
    let sourceFPS: Double?
    let settings: UpscaleSettings

    enum CodingKeys: String, CodingKey {
        case kind, sourceURL, durationSeconds, sourceWidth, sourceHeight, sourceFPS, settings
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("upscale", forKey: .kind)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(sourceWidth, forKey: .sourceWidth)
        try c.encodeIfPresent(sourceHeight, forKey: .sourceHeight)
        try c.encodeIfPresent(sourceFPS, forKey: .sourceFPS)
        try c.encode(settings, forKey: .settings)
    }
}

struct UpscaleSelectOption: Decodable, Sendable, Hashable {
    let value: String
    let label: String
    let description: String?
    let group: String?
    let groupDescription: String?
}

struct UpscaleSelectSetting: Decodable, Sendable, Identifiable {
    let id: String
    let label: String
    let options: [UpscaleSelectOption]
    let defaultValue: String
}

struct UpscaleNumericSetting: Decodable, Sendable, Identifiable {
    let id: String
    let label: String
    let minimum: Double
    let maximum: Double
    let step: Double
}

struct UpscaleToggleSetting: Decodable, Sendable, Identifiable {
    let id: String
    let label: String
    let defaultValue: Bool
}

struct UpscalePricing: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable { case perSecond, flat }
    struct MegapixelRate: Decodable, Sendable {
        let upTo: Double
        let credits: Double
    }

    let mode: Mode
    let ratesByResolution: [String: Double]?
    let sourceResolutionFloor: Bool?
    let fpsMultipliers: [String: Double]?
    let tierMultipliers: [String: Double]?
    let megapixelRates: [MegapixelRate]?
}

struct UpscaleModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [UpscaleModelConfig] { ModelCatalog.shared.upscale }

    @MainActor
    static func models(for type: ClipType) -> [UpscaleModelConfig] {
        allModels.filter { $0.supportedTypes.contains(type) }
    }

    let entry: CatalogEntry
    let caps: UpscaleCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var description: String? { entry.description }
    var paidOnly: Bool { entry.paidOnly }
    var creditsPerSecond: Double { entry.creditsPerSecondUpscale ?? 0 }
    var pricing: UpscalePricing? { entry.upscalePricing }
    var speed: String { caps.speed }
    var selectSettings: [UpscaleSelectSetting] { caps.selectSettings ?? [] }
    var numericSettings: [UpscaleNumericSetting] { caps.numericSettings ?? [] }
    var toggleSettings: [UpscaleToggleSetting] { caps.toggleSettings ?? [] }
    var supportedTypes: Set<ClipType> {
        Set(caps.supportedTypes.compactMap(ClipType.init(rawValue:)))
    }

    var defaultSettings: UpscaleSettings {
        UpscaleSettings(
            selections: Dictionary(uniqueKeysWithValues: selectSettings.map { ($0.id, $0.defaultValue) }),
            toggles: Dictionary(uniqueKeysWithValues: toggleSettings.map { ($0.id, $0.defaultValue) })
        )
    }

    @MainActor
    func supports(source: MediaAsset) -> Bool {
        guard supportedTypes.contains(source.type) else { return false }
        guard source.type != .video || (source.sourceFPS ?? 0) <= 60
                || selectSettings.contains(where: { $0.id == "targetFPS" }) else { return false }
        return selectSettings.allSatisfy { setting in
            setting.id != "targetResolution" || !availableOptions(for: setting, source: source).isEmpty
        }
    }

    @MainActor
    func availableOptions(for setting: UpscaleSelectSetting, source: MediaAsset?) -> [UpscaleSelectOption] {
        guard let source else { return setting.options }
        switch setting.id {
        case "targetResolution":
            guard let width = source.sourceWidth, let height = source.sourceHeight else { return setting.options }
            let sourceEdge = max(width, height)
            let maximum = setting.options.max(by: { targetLongEdge($0.value) < targetLongEdge($1.value) })
            return setting.options.filter {
                let factor = max(1, Double(targetLongEdge($0.value)) / Double(sourceEdge))
                let withinLimit = caps.maximumUpscaleFactor.map { factor <= $0 } ?? true
                return withinLimit && (targetLongEdge($0.value) >= sourceEdge || $0 == maximum)
            }
        case "targetFPS":
            guard let fps = source.sourceFPS, fps > 0 else { return setting.options }
            if fps > 60 { return setting.options.filter { $0.value == "60" } }
            let preservesSource = setting.options.contains(where: { $0.value == "source" })
            return setting.options.filter {
                $0.value == "source" || (Double($0.value) ?? 0) >= fps + (preservesSource ? 0.001 : 0)
            }
        default:
            return setting.options
        }
    }

    @MainActor
    func normalizedSettings(_ settings: UpscaleSettings, source: MediaAsset?) -> UpscaleSettings {
        var normalized = settings
        for setting in selectSettings {
            let options = availableOptions(for: setting, source: source)
            guard !options.isEmpty else { continue }
            let selected = normalized.selections[setting.id] ?? setting.defaultValue
            if !options.contains(where: { $0.value == selected }) {
                normalized.selections[setting.id] = options.last?.value
            }
        }
        return normalized
    }

    private func targetLongEdge(_ value: String) -> Int {
        value == "1080p" ? 1920 : 3840
    }
}
