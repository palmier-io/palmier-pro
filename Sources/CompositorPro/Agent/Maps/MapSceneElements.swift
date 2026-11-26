import CoreGraphics
import Foundation

enum MapSceneEntrance: String, Codable, Sendable, CaseIterable {
    case none, fade, pop, slide, typewriter
}

enum MapSceneEasing: String, Codable, Sendable, CaseIterable {
    case linear, easeInOut, easeOut, hold

    func value(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .linear: return t
        case .easeInOut: return t * t * (3 - 2 * t)
        case .easeOut: return 1 - pow(1 - t, 3)
        case .hold: return t < 1 ? 0 : 1
        }
    }
}

enum MapSceneObjectKind: String, Codable, Sendable, CaseIterable {
    case ship, airplane, truck, train, package, person, factory, money, tank
    case arrow, pin, circle, gunfire, explosion, heat, rain, image, flag
}

struct MapSceneRegion: Codable, Sendable, Equatable {
    var name: String
    var id: String?
    var label: String?
    var showLabel: Bool?
    var polygon: [[Double]]?
    var componentIndices: [Int]?
    var color: String?
    var opacity: Double?
    var imageMediaRef: String?
    var revealFrame: Int?
    var endFrame: Int?
    var pulse: Bool?
    var claimIds: [String]?
}

struct MapSceneWaypoint: Codable, Sendable, Equatable {
    var frame: Int
    var place: String?
    var latitude: Double?
    var longitude: Double?
}

struct MapSceneObject: Codable, Sendable, Equatable {
    var id: String
    var kind: MapSceneObjectKind
    var place: String?
    var latitude: Double?
    var longitude: Double?
    var routeId: String?
    var waypoints: [MapSceneWaypoint]?
    var startFrame: Int?
    var endFrame: Int?
    var size: Double?
    var color: String?
    var label: String?
    var imageMediaRef: String?
    var loopCount: Int?
    var rotateToPath: Bool?
    var rotation: Double?
    var easing: MapSceneEasing?
    var entrance: MapSceneEntrance?
}

struct MapSceneText: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var place: String?
    var x: Double?
    var y: Double?
    var startFrame: Int?
    var endFrame: Int?
    var fontSize: Double?
    var color: String?
    var entrance: MapSceneEntrance?
    var rotation: Double?
}

struct MapSceneBackgroundImage: Codable, Sendable, Equatable {
    var mediaRef: String
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    func validated() throws -> Self {
        _ = try MapSceneSpec.identifier(mediaRef)
        _ = try MapCoordinate(latitude: south, longitude: west).validated()
        _ = try MapCoordinate(latitude: north, longitude: east).validated()
        guard west < east, south < north else {
            throw MapSceneError.invalidSpec("Background image bounds need west < east and south < north; use an unwrapped image for dateline regions.")
        }
        return self
    }
}

struct MapScenePalette: Codable, Sendable, Equatable {
    var background: String = "#073D50"
    var land: String = "#355E45"
    var border: String = "#CBE8DB"
    var pin: String = "#FFD34E"
    var route: String = "#FFE389"
    var text: String = "#FFFFFF"
    var labelSize: Double = 32
    var glow: Double = 8
    var relief: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey { case background, land, border, pin, route, text, labelSize, glow, relief }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? background
        land = try c.decodeIfPresent(String.self, forKey: .land) ?? land
        border = try c.decodeIfPresent(String.self, forKey: .border) ?? border
        pin = try c.decodeIfPresent(String.self, forKey: .pin) ?? pin
        route = try c.decodeIfPresent(String.self, forKey: .route) ?? route
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        labelSize = try c.decodeIfPresent(Double.self, forKey: .labelSize) ?? labelSize
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? glow
        relief = try c.decodeIfPresent(Bool.self, forKey: .relief) ?? relief
    }

    func validated() throws -> Self {
        for color in [background, land, border, pin, route, text] { _ = try MapSceneColor(color) }
        guard labelSize.isFinite, (10...160).contains(labelSize), glow.isFinite, (0...32).contains(glow) else {
            throw MapSceneError.invalidSpec("Palette labelSize must be 10...160 and glow 0...32.")
        }
        return self
    }
}

struct MapSceneColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ value: String) throws {
        guard value.count == 7, value.first == "#", let rgb = UInt32(value.dropFirst(), radix: 16) else {
            throw MapSceneError.invalidSpec("Colors must use #RRGGBB hexadecimal notation.")
        }
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
    }

    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
}

struct MapSceneRegionRequest: Sendable {
    var id: String
    var regionId: String?
    var label: String
    var polygons: [[[MapCoordinate]]]
    var center: MapCoordinate
    var input: MapSceneRegion
}

struct MapSceneObjectRequest: Sendable {
    struct Key: Sendable {
        var frame: Int
        var coordinate: MapCoordinate
    }
    var input: MapSceneObject
    var keys: [Key]
    var start: Int
    var end: Int
}

struct MapSceneRecord: Codable, Sendable, Equatable {
    var input: MapSceneInput
    var digest: String
    var atlasVersion: String
    var rendererVersion: String
    var imageDigests: [String: String]
    var videoDigest: String
}

extension MapSceneSpec {
    static func namedLocation(_ name: String, atlas: MapAtlas, scenePlaces: [MapScenePlaceRequest]) throws -> MapSceneLocation {
        let key = MapAtlas.key(name)
        if let exact = scenePlaces.first(where: { MapAtlas.key($0.place.canonicalName) == key }) { return exact.place }
        let matches = scenePlaces.filter { $0.place.aliases.contains { MapAtlas.key($0) == key } }
        guard matches.count <= 1 else { throw MapSceneError.ambiguousPlace(name: name) }
        return try matches.first?.place ?? atlas.location(named: name)
    }

    static func location(
        place: String?, latitude: Double?, longitude: Double?, atlas: MapAtlas,
        scenePlaces: [MapScenePlaceRequest]
    ) throws -> MapCoordinate {
        if let place {
            guard latitude == nil, longitude == nil else {
                throw MapSceneError.invalidSpec("Use either a place or latitude/longitude, never both.")
            }
            return try namedLocation(place, atlas: atlas, scenePlaces: scenePlaces).coordinate.validated()
        }
        guard let latitude, let longitude else {
            throw MapSceneError.invalidSpec("Provide a known place or both latitude and longitude.")
        }
        return try MapCoordinate(latitude: latitude, longitude: longitude).validated()
    }

    mutating func validateElements(_ input: MapSceneInput, atlas: MapAtlas) throws {
        guard (input.regions?.count ?? 0) <= 64, (input.objects?.count ?? 0) <= 64,
              (input.texts?.count ?? 0) <= 64 else {
            throw MapSceneError.invalidSpec("A scene supports at most 64 regions, 64 objects and 64 text cues.")
        }
        var regionIds = Set<String>()
        for raw in input.regions ?? [] {
            let polygons: [[[MapCoordinate]]]
            let center: MapCoordinate
            let regionId: String?
            let label: String
            if let polygon = raw.polygon {
                guard raw.componentIndices == nil else {
                    throw MapSceneError.invalidSpec("componentIndices applies only to atlas regions.")
                }
                guard (4...4096).contains(polygon.count), polygon.first == polygon.last else {
                    throw MapSceneError.invalidSpec("Custom polygons need 4...4096 closed [longitude, latitude] vertices.")
                }
                let ring = try polygon.map { pair -> MapCoordinate in
                    guard pair.count == 2 else { throw MapSceneError.invalidSpec("Polygon vertices are [longitude, latitude] pairs.") }
                    return try MapCoordinate(latitude: pair[1], longitude: pair[0]).validated()
                }
                let origin = ring[0].longitude
                let area = zip(ring, ring.dropFirst()).reduce(0.0) { result, pair in
                    result + MapProjection.longitudeDelta(pair.0.longitude, from: origin) * pair.1.latitude
                        - MapProjection.longitudeDelta(pair.1.longitude, from: origin) * pair.0.latitude
                }
                guard abs(area) > 0.00000001 else { throw MapSceneError.invalidSpec("Custom polygons must enclose a nonzero area.") }
                polygons = [[ring]]
                center = Self.center(of: polygons)
                regionId = nil
                _ = try Self.identifier(raw.name)
                label = raw.label ?? raw.name
            } else {
                let region = try atlas.region(named: raw.name)
                if let indices = raw.componentIndices {
                    guard !indices.isEmpty, indices.count <= 32, Set(indices).count == indices.count,
                          indices.allSatisfy({ region.polygons.indices.contains($0) }) else {
                        throw MapSceneError.invalidSpec("componentIndices must contain unique indices from list_map_regions.")
                    }
                    polygons = indices.map { region.polygons[$0] }
                    center = Self.center(of: polygons)
                } else {
                    polygons = region.polygons
                    center = region.center
                }
                regionId = region.id
                label = raw.label ?? region.name
            }
            let id = try Self.identifier(raw.id ?? regionId ?? raw.name)
            guard regionIds.insert(id).inserted else { throw MapSceneError.invalidSpec("Region cue IDs must be unique; use id for repeated highlights.") }
            try Self.validateWindow(start: raw.revealFrame ?? 0, end: raw.endFrame ?? durationFrames, duration: durationFrames)
            _ = try MapSceneColor(raw.color ?? palette.pin)
            let opacity = raw.opacity ?? 0.75
            guard opacity.isFinite, (0...1).contains(opacity) else { throw MapSceneError.invalidSpec("Region opacity must be 0...1.") }
            _ = try Self.text(label, maximum: 120)
            _ = try Self.claims(raw.claimIds)
            if let reference = raw.imageMediaRef { _ = try Self.identifier(reference) }
            var canonical = raw
            canonical.name = regionId ?? raw.name
            canonical.id = id
            regions.append(.init(id: id, regionId: regionId, label: label, polygons: polygons, center: center, input: canonical))
        }
        var objectIds = Set<String>()
        for raw in input.objects ?? [] {
            guard objectIds.insert(try Self.identifier(raw.id)).inserted else {
                throw MapSceneError.invalidSpec("Object IDs must be unique.")
            }
            let start = raw.startFrame ?? 0, end = raw.endFrame ?? durationFrames
            try Self.validateWindow(start: start, end: end, duration: durationFrames)
            let size = raw.size ?? 54
            guard size.isFinite, (8...320).contains(size), (1...16).contains(raw.loopCount ?? 1) else {
                throw MapSceneError.invalidSpec("Object size must be 8...320 and loopCount 1...16.")
            }
            _ = try MapSceneColor(raw.color ?? palette.text)
            let rotation = raw.rotation ?? 0
            guard rotation.isFinite, (-180...180).contains(rotation) else {
                throw MapSceneError.invalidSpec("Object rotation must be -180...180 degrees.")
            }
            if let label = raw.label { _ = try Self.text(label, maximum: 80) }
            if let reference = raw.imageMediaRef { _ = try Self.identifier(reference) }
            if raw.imageMediaRef != nil, raw.kind != .image, raw.kind != .flag {
                throw MapSceneError.invalidSpec("imageMediaRef applies only to image or flag objects.")
            }
            if raw.kind == .image || raw.kind == .flag {
                guard raw.imageMediaRef != nil else { throw MapSceneError.invalidSpec("Image and flag objects need imageMediaRef.") }
            }
            if raw.entrance == .typewriter { throw MapSceneError.invalidSpec("Typewriter is a text entrance, not an object entrance.") }
            let hasAnchor = raw.place != nil || raw.latitude != nil || raw.longitude != nil
            guard [hasAnchor, raw.routeId != nil, raw.waypoints != nil].filter({ $0 }).count == 1 else {
                throw MapSceneError.invalidSpec("An object needs exactly one anchor, routeId, or waypoint path.")
            }
            let keys: [MapSceneObjectRequest.Key]
            if let routeId = raw.routeId {
                guard connections.contains(where: { $0.id == routeId }) else {
                    throw MapSceneError.invalidSpec("Unknown object routeId '\(routeId)'.")
                }
                keys = []
            } else if let waypoints = raw.waypoints {
                guard (raw.loopCount ?? 1) == 1 else {
                    throw MapSceneError.invalidSpec("Timed waypoints cannot loop; repeat their frame keys, or use a looping route object.")
                }
                guard (2...128).contains(waypoints.count) else { throw MapSceneError.invalidSpec("Moving objects need 2...128 waypoints.") }
                var previous = -1
                keys = try waypoints.map { key in
                    guard (start..<end).contains(key.frame), key.frame > previous else { throw MapSceneError.invalidFrame }
                    previous = key.frame
                    return .init(frame: key.frame, coordinate: try Self.location(place: key.place, latitude: key.latitude,
                        longitude: key.longitude, atlas: atlas, scenePlaces: places))
                }
            } else {
                guard (raw.loopCount ?? 1) == 1, raw.rotateToPath != true else {
                    throw MapSceneError.invalidSpec("loopCount and rotateToPath require a moving object.")
                }
                keys = [.init(frame: start, coordinate: try Self.location(place: raw.place, latitude: raw.latitude,
                    longitude: raw.longitude, atlas: atlas, scenePlaces: places))]
            }
            var canonical = raw
            if raw.waypoints != nil {
                canonical.waypoints = keys.map { .init(frame: $0.frame, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            } else if let key = keys.first {
                canonical.place = nil
                canonical.latitude = key.coordinate.latitude
                canonical.longitude = key.coordinate.longitude
            }
            objects.append(.init(input: canonical, keys: keys, start: start, end: end))
        }
        var textIds = Set<String>()
        for raw in input.texts ?? [] {
            guard textIds.insert(try Self.identifier(raw.id)).inserted else { throw MapSceneError.invalidSpec("Text IDs must be unique.") }
            _ = try Self.text(raw.text, maximum: raw.entrance == .typewriter ? 80 : 240)
            try Self.validateWindow(start: raw.startFrame ?? 0, end: raw.endFrame ?? durationFrames, duration: durationFrames)
            let size = raw.fontSize ?? 48, rotation = raw.rotation ?? 0
            guard size.isFinite, (10...240).contains(size), rotation.isFinite, (-180...180).contains(rotation) else {
                throw MapSceneError.invalidSpec("Text fontSize must be 10...240 and rotation -180...180.")
            }
            _ = try MapSceneColor(raw.color ?? palette.text)
            if let place = raw.place {
                guard raw.x == nil, raw.y == nil else { throw MapSceneError.invalidSpec("Geographic text cannot also have screen x/y coordinates.") }
                _ = try Self.location(place: place, latitude: nil, longitude: nil, atlas: atlas, scenePlaces: places)
            } else {
                guard (raw.x ?? 0.5).isFinite, (raw.y ?? 0.15).isFinite,
                      (0...1).contains(raw.x ?? 0.5), (0...1).contains(raw.y ?? 0.15) else {
                    throw MapSceneError.invalidSpec("Screen text x/y must be normalized 0...1 values.")
                }
            }
            var canonical = raw
            if let place = raw.place { canonical.place = try Self.namedLocation(place, atlas: atlas, scenePlaces: places).canonicalName }
            texts.append(canonical)
        }
    }

    static func validateWindow(start: Int, end: Int, duration: Int) throws {
        guard start >= 0, start < end, end <= duration else { throw MapSceneError.invalidFrame }
    }

    static func center(of polygons: [[[MapCoordinate]]]) -> MapCoordinate {
        let points = polygons.flatMap { Array(($0.first ?? []).dropLast()) }
        let angles = points.map { $0.longitude * .pi / 180 }
        return .init(latitude: points.map(\.latitude).reduce(0, +) / Double(max(1, points.count)),
            longitude: atan2(angles.map { sin($0) }.reduce(0, +), angles.map { cos($0) }.reduce(0, +)) * 180 / .pi)
    }

    static func identifier(_ value: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 160,
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw MapSceneError.invalidSpec("IDs and names must be non-empty single-line values up to 160 characters.")
        }
        return value
    }

    static func text(_ value: String, maximum: Int) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= maximum, !value.contains("\0") else {
            throw MapSceneError.invalidSpec("Text must contain 1...\(maximum) characters.")
        }
        return value
    }

    static func claims(_ values: [String]?) throws -> [String] {
        let result = try (values ?? []).map { try identifier($0) }
        guard result.count <= 128, Set(result).count == result.count else {
            throw MapSceneError.invalidSpec("Claim IDs must be unique, with at most 128 per cue.")
        }
        return result
    }
}
