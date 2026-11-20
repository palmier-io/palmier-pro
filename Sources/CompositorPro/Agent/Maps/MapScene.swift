import CoreGraphics
import CryptoKit
import Foundation

// Resolved coordinates are editorial anchors, not survey measurements.
struct MapSceneLocation: Codable, Sendable, Equatable {
    let canonicalName: String
    let aliases: [String]
    let latitude: Double
    let longitude: Double
    let island: Bool
    let note: String
    var regionId: String? = nil
    var coordinate: MapCoordinate { .init(latitude: latitude, longitude: longitude) }
}

enum MalaysiaPlaceCatalog {
    static let places: [MapSceneLocation] = [
        .init(canonicalName: "Penang", aliases: ["Penang", "George Town"], latitude: 5.414, longitude: 100.332, island: true, note: "Island state capital area."),
        .init(canonicalName: "Bayan Lepas", aliases: ["Bayan Lepas"], latitude: 5.297, longitude: 100.263, island: true, note: "Penang island industrial zone."),
        .init(canonicalName: "Butterworth", aliases: ["Butterworth"], latitude: 5.398, longitude: 100.363, island: false, note: "Mainland Penang (Seberang Perai)."),
        .init(canonicalName: "Kulim", aliases: ["Kulim"], latitude: 5.366, longitude: 100.562, island: false, note: "Kedah industrial hub."),
        .init(canonicalName: "Kuala Lumpur", aliases: ["Kuala Lumpur", "KL"], latitude: 3.139, longitude: 101.686, island: false, note: "Federal capital."),
        .init(canonicalName: "Petaling Jaya", aliases: ["Petaling Jaya", "PJ"], latitude: 3.107, longitude: 101.606, island: false, note: "Selangor industrial city."),
        .init(canonicalName: "Shah Alam", aliases: ["Shah Alam"], latitude: 3.073, longitude: 101.518, island: false, note: "Selangor state capital."),
        .init(canonicalName: "Cyberjaya", aliases: ["Cyberjaya"], latitude: 2.926, longitude: 101.656, island: false, note: "Selangor tech hub."),
        .init(canonicalName: "Ipoh", aliases: ["Ipoh"], latitude: 4.597, longitude: 101.090, island: false, note: "Perak capital."),
        .init(canonicalName: "Melaka", aliases: ["Melaka", "Malacca"], latitude: 2.189, longitude: 102.251, island: false, note: "Melaka state capital."),
        .init(canonicalName: "Johor Bahru", aliases: ["Johor Bahru", "JB"], latitude: 1.492, longitude: 103.761, island: false, note: "Johor state capital."),
        .init(canonicalName: "Tanjung Pelepas", aliases: ["Tanjung Pelepas", "PTP"], latitude: 1.365, longitude: 103.547, island: false, note: "Johor container port."),
    ]

    /// Coordinates are approximate town centroids for editorial illustration.
    static let datasetNote = "Approximate WGS-84 centroids (OpenStreetMap-scale), for map illustration only; not survey-grade."

    static func resolve(_ rawName: String) throws -> MapSceneLocation {
        let key = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { throw MapSceneError.unresolvedPlace(name: rawName) }
        let matches = places.filter { place in
            place.canonicalName.lowercased() == key || place.aliases.contains(where: { $0.lowercased() == key })
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw MapSceneError.unresolvedPlace(name: rawName)
        default: throw MapSceneError.ambiguousPlace(name: rawName)
        }
    }
}

enum MapSceneError: LocalizedError, Equatable {
    case unresolvedPlace(name: String)
    case ambiguousPlace(name: String)
    case duplicatePlace(name: String)
    case invalidFrame
    case invalidZoom
    case connectionNeedsClaims(from: String, to: String)
    case invalidSpec(String)

    var errorDescription: String? {
        switch self {
        case .unresolvedPlace(let name):
            "Place '\(name)' is not in the map catalog. Use list_map_regions for exact region IDs, or supply an explicit WGS-84 coordinate. \(MalaysiaPlaceCatalog.datasetNote)"
        case .ambiguousPlace(let name):
            "Place '\(name)' matches more than one catalog entry; use a canonical name."
        case .duplicatePlace(let name):
            "Place '\(name)' is listed twice; each scene place must be unique."
        case .invalidFrame:
            "Camera and reveal frames must be within the scene duration."
        case .invalidZoom:
            "Camera zoom must be finite, between 0.05 and 128."
        case .connectionNeedsClaims(let from, let to):
            "Sourced connection '\(from)' → '\(to)' needs at least one claimId; use kind illustrative instead."
        case .invalidSpec(let detail):
            detail
        }
    }
}

struct MapScenePlace: Codable, Sendable, Equatable {
    var name: String
    var label: String?
    var claimIds: [String]?
    var revealFrame: Int?
    var latitude: Double?
    var longitude: Double?
    var showPin: Bool?
    var showLabel: Bool?
}

struct MapSceneConnection: Codable, Sendable, Equatable {
    var from: String
    var to: String
    var kind: String?
    var claimIds: [String]?
    var revealFrame: Int?
    var id: String?
    var endFrame: Int?
    var revealFrames: Int?
    var via: [MapCoordinate]?
    var arc: Double?
    var color: String?
    var width: Double?
    var label: String?
    var distanceLabel: Bool?
}

struct MapSceneCameraKey: Codable, Sendable, Equatable {
    var frame: Int
    var place: String?
    var zoom: Double?
    var latitude: Double?
    var longitude: Double?
    var rotation: Double?
    var tilt: Double?
    var easing: MapSceneEasing?
}

struct MapSceneInput: Codable, Sendable, Equatable {
    var places: [MapScenePlace]
    var connections: [MapSceneConnection]?
    var camera: [MapSceneCameraKey]?
    var durationFrames: Int?
    var width: Int?
    var height: Int?
    var regions: [MapSceneRegion]?
    var objects: [MapSceneObject]?
    var texts: [MapSceneText]?
    var fps: Int?
    var palette: MapScenePalette?
    var backgroundImage: MapSceneBackgroundImage?
}

struct MapScenePlaceRequest: Sendable {
    var place: MapSceneLocation
    var label: String
    var claimIds: [String]
    var revealFrame: Int
    var showPin: Bool
    var showLabel: Bool
}

struct MapSceneConnectionRequest: Sendable {
    var from: MapSceneLocation
    var to: MapSceneLocation
    var sourced: Bool
    var claimIds: [String]
    var revealFrame: Int
    var id: String
    var input: MapSceneConnection
}

struct MapSceneCameraRequest: Sendable {
    var frame: Int
    var center: MapSceneLocation
    var zoom: Double
    var rotation: Double = 0
    var tilt: Double = 0
    var easing: MapSceneEasing = .easeInOut
}

struct MapSceneSpec: Sendable {
    var places: [MapScenePlaceRequest]
    var connections: [MapSceneConnectionRequest]
    var camera: [MapSceneCameraRequest]
    var durationFrames: Int
    var width: Int
    var height: Int
    var fps: Int = 30
    var palette: MapScenePalette = MapScenePalette()
    var regions: [MapSceneRegionRequest] = []
    var objects: [MapSceneObjectRequest] = []
    var texts: [MapSceneText] = []
    var atlasVersion: String = "centroids"
    var extentCoordinates: [MapCoordinate] = []
    var backgroundImage: MapSceneBackgroundImage?

    @concurrent static func resolve(_ input: MapSceneInput, defaultWidth: Int, defaultHeight: Int,
                                   defaultFPS: Int, atlas: MapAtlas) async throws -> Self {
        try Task.checkCancellation()
        return try validated(input, defaultWidth: defaultWidth, defaultHeight: defaultHeight, defaultFPS: defaultFPS, atlas: atlas)
    }

    static func validated(_ input: MapSceneInput, defaultWidth: Int, defaultHeight: Int,
                          defaultFPS: Int = 30, atlas: MapAtlas = .empty) throws -> MapSceneSpec {
        let fps = input.fps ?? defaultFPS
        guard (1...120).contains(fps) else { throw MapSceneError.invalidSpec("fps must be 1...120.") }
        let duration = input.durationFrames ?? fps * 8
        guard (1...(fps * 180)).contains(duration) else {
            throw MapSceneError.invalidSpec("durationFrames must be positive and at most 180 seconds at the scene fps.")
        }
        let width = input.width ?? defaultWidth
        let height = input.height ?? defaultHeight
        guard (320...3840).contains(width), (180...3840).contains(height), width * height <= 8_294_400 else {
            throw MapSceneError.invalidSpec("Canvas must be 320...3840 by 180...3840, at most 8,294,400 pixels.")
        }
        guard (1...64).contains(input.places.count), (input.connections?.count ?? 0) <= 64,
              (input.camera?.count ?? 0) <= 128 else {
            throw MapSceneError.invalidSpec("A scene needs 1...64 places, at most 64 routes and 128 camera keys.")
        }
        var seen = Set<String>()
        var places: [MapScenePlaceRequest] = []
        for raw in input.places {
            _ = try identifier(raw.name)
            let place: MapSceneLocation
            if raw.latitude != nil || raw.longitude != nil {
                let coordinate = try location(place: nil, latitude: raw.latitude, longitude: raw.longitude,
                                              atlas: atlas, scenePlaces: [])
                place = .init(canonicalName: raw.name, aliases: [], latitude: coordinate.latitude,
                              longitude: coordinate.longitude, island: false, note: "Explicit caller-supplied WGS-84 coordinate.",
                              regionId: atlas.regions.first(where: { $0.id == raw.name })?.id)
            } else {
                place = try atlas.location(named: raw.name)
                _ = try place.coordinate.validated()
            }
            guard seen.insert(MapAtlas.key(place.canonicalName)).inserted else { throw MapSceneError.duplicatePlace(name: raw.name) }
            let reveal = raw.revealFrame ?? 0
            guard (0..<duration).contains(reveal) else { throw MapSceneError.invalidFrame }
            let claimIds = try claims(raw.claimIds)
            let trimmedLabel = raw.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let defaultLabel = atlas.regions.first(where: { $0.id == place.regionId })?.name ?? place.canonicalName
            let label = trimmedLabel.isEmpty ? defaultLabel : trimmedLabel
            _ = try text(label, maximum: 120)
            places.append(MapScenePlaceRequest(place: place, label: label, claimIds: claimIds, revealFrame: reveal, showPin: raw.showPin ?? true, showLabel: raw.showLabel ?? true))
        }
        func resolvedPlace(_ raw: String) throws -> MapSceneLocation {
            try Self.namedLocation(raw, atlas: atlas, scenePlaces: places)
        }
        let scoped = Set(places.map(\.place.canonicalName))
        var connections: [MapSceneConnectionRequest] = []
        var connectionIds = Set<String>()
        for raw in input.connections ?? [] {
            let from = try resolvedPlace(raw.from)
            let to = try resolvedPlace(raw.to)
            guard scoped.contains(from.canonicalName), scoped.contains(to.canonicalName) else {
                throw MapSceneError.invalidSpec("Connection endpoints must be scene places.")
            }
            let kind = (raw.kind ?? "illustrative").lowercased()
            guard ["illustrative", "sourced"].contains(kind) else {
                throw MapSceneError.invalidSpec("Connection kind must be illustrative or sourced.")
            }
            let claimIds = try claims(raw.claimIds)
            if kind == "sourced", claimIds.isEmpty {
                throw MapSceneError.connectionNeedsClaims(from: from.canonicalName, to: to.canonicalName)
            }
            let reveal = raw.revealFrame ?? 0
            try validateWindow(start: reveal, end: raw.endFrame ?? duration, duration: duration)
            let id = try identifier(raw.id ?? "\(from.canonicalName) → \(to.canonicalName)")
            guard connectionIds.insert(id).inserted, from.latitude != to.latitude
                    || MapProjection.longitudeDelta(from.longitude, from: to.longitude) != 0 else {
                throw MapSceneError.invalidSpec("Routes need distinct endpoints and unique IDs.")
            }
            guard (0...120).contains(raw.revealFrames ?? 18), (raw.via?.count ?? 0) <= 128,
                  (raw.arc ?? 0).isFinite, (-1...1).contains(raw.arc ?? 0),
                  (raw.width ?? 4).isFinite, (1...24).contains(raw.width ?? 4) else {
                throw MapSceneError.invalidSpec("Route revealFrames must be 0...120, arc -1...1, width 1...24, with at most 128 via coordinates.")
            }
            guard (raw.via ?? []).isEmpty || (raw.arc ?? 0) == 0 else {
                throw MapSceneError.invalidSpec("Use via coordinates or arc curvature, never both.")
            }
            for point in raw.via ?? [] { _ = try point.validated() }
            _ = try MapSceneColor(raw.color ?? "#FFE389")
            if let label = raw.label { _ = try text(label, maximum: 120) }
            let availableRevealFrames = (raw.endFrame ?? duration) - reveal - 1
            guard (raw.revealFrames ?? 0) <= availableRevealFrames else {
                throw MapSceneError.invalidSpec("A route reveal must complete before its exclusive endFrame.")
            }
            var canonical = raw
            canonical.revealFrames = raw.revealFrames ?? min(18, availableRevealFrames)
            canonical.from = from.canonicalName; canonical.to = to.canonicalName; canonical.id = id
            connections.append(.init(from: from, to: to, sourced: kind == "sourced", claimIds: claimIds,
                                     revealFrame: reveal, id: id, input: canonical))
        }
        var camera: [MapSceneCameraRequest] = []
        var cameraFrames = Set<Int>()
        for raw in input.camera ?? [] {
            guard (0..<duration).contains(raw.frame), cameraFrames.insert(raw.frame).inserted else { throw MapSceneError.invalidFrame }
            let zoom = raw.zoom ?? 1
            guard zoom.isFinite, (0.05...128).contains(zoom) else { throw MapSceneError.invalidZoom }
            let coordinate = try location(place: raw.place, latitude: raw.latitude, longitude: raw.longitude,
                                          atlas: atlas, scenePlaces: places)
            let rotation = raw.rotation ?? 0, tilt = raw.tilt ?? 0
            guard rotation.isFinite, (-180...180).contains(rotation), tilt.isFinite, (0...60).contains(tilt) else {
                throw MapSceneError.invalidSpec("Camera rotation must be -180...180 and tilt 0...60 degrees.")
            }
            let center = MapSceneLocation(canonicalName: raw.place ?? "camera", aliases: [],
                latitude: coordinate.latitude, longitude: coordinate.longitude, island: false, note: "Authored camera center.")
            camera.append(.init(frame: raw.frame, center: center, zoom: zoom, rotation: rotation, tilt: tilt, easing: raw.easing ?? .easeInOut))
        }
        if camera.isEmpty, let first = places.first {
            camera = [MapSceneCameraRequest(frame: 0, center: first.place, zoom: 1)]
        }
        camera.sort { $0.frame < $1.frame }
        var spec = MapSceneSpec(places: places, connections: connections, camera: camera,
                                durationFrames: duration, width: width, height: height)
        spec.fps = fps
        spec.palette = try (input.palette ?? MapScenePalette()).validated()
        spec.backgroundImage = try input.backgroundImage?.validated()
        spec.atlasVersion = atlas.version
        try spec.validateElements(input, atlas: atlas)
        spec.extentCoordinates = spec.regions.flatMap { $0.polygons.flatMap { $0.flatMap { $0 } } }
        if spec.extentCoordinates.isEmpty {
            let ids = Set(spec.places.compactMap(\.place.regionId))
            spec.extentCoordinates = atlas.regions.filter { ids.contains($0.id) }
                .flatMap { $0.polygons.flatMap { $0.flatMap { $0 } } }
        }
        spec.extentCoordinates += spec.objects.flatMap { $0.keys.map(\.coordinate) }
        spec.extentCoordinates += spec.connections.flatMap { $0.input.via ?? [] }
        if let background = spec.backgroundImage {
            spec.extentCoordinates += [.init(latitude: background.south, longitude: background.west),
                                       .init(latitude: background.north, longitude: background.east)]
        }
        return spec
    }
}

/// Equirectangular projection about the scene center latitude. Plane is canvas
/// units, y-down, origin at the extent center.
enum MapProjection {
    struct Frame: Sendable {
        /// Canvas-plane position (y-down, origin at the extent center) per place.
        var points: [CGPoint]
        var baseScale: Double
        var center: CGPoint
        var latitude0: Double
        var longitude0: Double
        var cosine: Double
    }

    static func frame(for spec: MapSceneSpec) -> Frame {
        let lat0 = spec.places.map(\.place.latitude).reduce(0, +) / Double(spec.places.count)
        let longitudes = spec.places.map { $0.place.longitude * .pi / 180 }
        let lon0 = atan2(longitudes.map { sin($0) }.reduce(0, +), longitudes.map { cos($0) }.reduce(0, +)) * 180 / .pi
        let cosine = cos(lat0 * .pi / 180)
        func planar(_ place: MapSceneLocation) -> (x: Double, y: Double) {
            // Equirectangular: meters per degree latitude ≈ constant, longitude scaled by cos(lat).
            (longitudeDelta(place.longitude, from: lon0) * cosine, (lat0 - place.latitude))
        }
        let raw = spec.places.map { planar($0.place) }
        let extent = raw + spec.extentCoordinates.map {
            (x: longitudeDelta($0.longitude, from: lon0) * cosine, y: lat0 - $0.latitude)
        }
        let spanX = max(0.2, (extent.map(\.x).max() ?? 0) - (extent.map(\.x).min() ?? 0))
        let spanY = max(0.2, (extent.map(\.y).max() ?? 0) - (extent.map(\.y).min() ?? 0))
        let baseScale = min(Double(spec.width) * 0.8 / spanX, Double(spec.height) * 0.8 / spanY)
        let center = CGPoint(x: Double(spec.width) / 2, y: Double(spec.height) / 2)
        let points = raw.map { CGPoint(x: $0.x * baseScale, y: $0.y * baseScale) }
        return Frame(points: points, baseScale: baseScale, center: center, latitude0: lat0, longitude0: lon0, cosine: cosine)
    }

    static func point(of place: MapSceneLocation, in frame: Frame) -> CGPoint {
        CGPoint(x: longitudeDelta(place.longitude, from: frame.longitude0) * frame.cosine * frame.baseScale,
                y: (frame.latitude0 - place.latitude) * frame.baseScale)
    }

    static func longitudeDelta(_ longitude: Double, from origin: Double) -> Double {
        var delta = (longitude - origin).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    static func point(_ coordinate: MapCoordinate, in frame: Frame) -> CGPoint {
        CGPoint(x: longitudeDelta(coordinate.longitude, from: frame.longitude0) * frame.cosine * frame.baseScale,
                y: (frame.latitude0 - coordinate.latitude) * frame.baseScale)
    }

    /// Screen position of a plane point under a camera key (render-test oracle).
    static func screen(_ plane: CGPoint, camera: MapSceneCameraRequest, in frame: Frame) -> CGPoint {
        plane.applying(transform(camera, in: frame))
    }

    static func transform(_ camera: MapSceneCameraRequest, in frame: Frame) -> CGAffineTransform {
        let center = point(of: camera.center, in: frame)
        let angle = camera.rotation * .pi / 180
        let x = camera.zoom, y = camera.zoom * cos(camera.tilt * .pi / 180)
        let a = x * cos(angle), b = x * sin(angle), c = -y * sin(angle), d = y * cos(angle)
        return CGAffineTransform(a: a, b: b, c: c, d: d,
            tx: frame.center.x - a * center.x - c * center.y,
            ty: frame.center.y - b * center.x - d * center.y)
    }
}

extension MapSceneSpec {
    var authoredInput: MapSceneInput {
        MapSceneInput(
            places: places.map { .init(name: $0.place.canonicalName, label: $0.label, claimIds: $0.claimIds,
                revealFrame: $0.revealFrame, latitude: $0.place.latitude, longitude: $0.place.longitude,
                showPin: $0.showPin, showLabel: $0.showLabel) },
            connections: connections.map(\.input),
            camera: camera.map { .init(frame: $0.frame, zoom: $0.zoom, latitude: $0.center.latitude,
                longitude: $0.center.longitude, rotation: $0.rotation, tilt: $0.tilt, easing: $0.easing) },
            durationFrames: durationFrames, width: width, height: height,
            regions: regions.map(\.input), objects: objects.map(\.input), texts: texts, fps: fps, palette: palette,
            backgroundImage: backgroundImage)
    }

    var digest: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(authoredInput)
            let identity = Data((atlasVersion + "|" + MapSceneRenderer.version).utf8) + bytes
            return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        }
    }

    func camera(at frame: Int) -> MapSceneCameraRequest {
        guard let first = camera.first, let last = camera.last else { preconditionFailure("Validated maps have a camera.") }
        guard frame > first.frame else { return first }
        guard frame < last.frame else { return last }
        let index = camera.firstIndex { $0.frame > frame }!
        let before = camera[index - 1], after = camera[index]
        let progress = after.easing.value(Double(frame - before.frame) / Double(after.frame - before.frame))
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        var result = before
        let longitude = before.center.longitude + MapProjection.longitudeDelta(after.center.longitude, from: before.center.longitude) * progress
        result.center = .init(canonicalName: "camera", aliases: [], latitude: blend(before.center.latitude, after.center.latitude),
                              longitude: longitude, island: false, note: "Interpolated camera center.")
        result.zoom = exp(blend(log(before.zoom), log(after.zoom)))
        result.rotation = before.rotation + MapProjection.longitudeDelta(after.rotation, from: before.rotation) * progress
        result.tilt = blend(before.tilt, after.tilt)
        result.frame = frame
        return result
    }
}
