import CoreMedia
import Foundation

struct ObjectMask: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var seed: MaskSeed
    var enabled: Bool = true
    var inverted: Bool = false
    var feather: Double = 0
    var expansion: Double = 0
    var removesBackground: Bool = false
    var track: MaskTrack?

    init(
        id: String = UUID().uuidString,
        seed: MaskSeed,
        enabled: Bool = true,
        inverted: Bool = false,
        feather: Double = 0,
        expansion: Double = 0,
        removesBackground: Bool = false,
        track: MaskTrack? = nil
    ) {
        self.id = id
        self.seed = seed
        self.enabled = enabled
        self.inverted = inverted
        self.feather = feather
        self.expansion = expansion
        self.removesBackground = removesBackground
        self.track = track
    }

    private enum CodingKeys: String, CodingKey {
        case id, seed, enabled, inverted, feather, expansion, removesBackground, track
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            seed: try c.decode(MaskSeed.self, forKey: .seed),
            enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? true,
            inverted: (try? c.decode(Bool.self, forKey: .inverted)) ?? false,
            feather: (try? c.decode(Double.self, forKey: .feather)) ?? 0,
            expansion: (try? c.decode(Double.self, forKey: .expansion)) ?? 0,
            removesBackground: (try? c.decode(Bool.self, forKey: .removesBackground)) ?? false,
            track: try? c.decode(MaskTrack.self, forKey: .track)
        )
    }
}

enum MaskSeed: Sendable, Equatable {
    case text(String)
    case point(MaskPointSeed)
}

struct MaskPointSeed: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var sourceTime: MaskSourceTime
}

struct MaskSourceTime: Codable, Sendable, Equatable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) {
        value = time.value
        timescale = max(1, time.timescale)
    }

    var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }
}

extension MaskSeed: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, point
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "point":
            self = .point(try c.decode(MaskPointSeed.self, forKey: .point))
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unsupported mask seed type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .point(let point):
            try c.encode("point", forKey: .type)
            try c.encode(point, forKey: .point)
        }
    }
}
