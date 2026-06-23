import Foundation

/// One entry in a clip's ordered effect stack
struct Effect: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: String
    var enabled: Bool = true
    var params: [String: EffectParam] = [:]

    init(id: String = UUID().uuidString, type: String, enabled: Bool = true,
         params: [String: EffectParam] = [:]) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, enabled, params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(String.self, forKey: .type),
            enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? true,
            params: (try? c.decode([String: EffectParam].self, forKey: .params)) ?? [:]
        )
    }
}

/// A single effect parameter
struct EffectParam: Codable, Sendable, Equatable {
    var value: Double?
    var string: String?
    var track: KeyframeTrack<Double>?

    init(value: Double? = nil, string: String? = nil, track: KeyframeTrack<Double>? = nil) {
        self.value = value
        self.string = string
        self.track = track
    }

    /// Effective numeric value at a clip-relative frame offset.
    func resolved(at offset: Int, default defaultValue: Double) -> Double {
        if let track, track.isActive {
            return track.sample(at: offset, fallback: value ?? defaultValue)
        }
        return value ?? defaultValue
    }
}

extension Effect {
    /// Convenience for static numeric params.
    static func make(_ type: String, _ values: [String: Double] = [:]) -> Effect {
        Effect(type: type, params: values.mapValues { EffectParam(value: $0) })
    }
}
