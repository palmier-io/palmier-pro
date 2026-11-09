import CoreGraphics
import Foundation

/// One projection (equirectangular, adequate at Peninsula Malaysia extents) and a
/// small resolved-place catalog. Unknown or ambiguous names are refused, never
/// guessed; coordinates are approximate WGS-84 centroids for illustration.
struct MalaysiaPlace: Sendable, Equatable {
    let canonicalName: String
    let aliases: [String]
    let latitude: Double
    let longitude: Double
    let island: Bool
    let note: String
}

enum MalaysiaPlaceCatalog {
    static let places: [MalaysiaPlace] = [
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

    static func resolve(_ rawName: String) throws -> MalaysiaPlace {
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
            "Place '\(name)' is not in the map catalog (\(MalaysiaPlaceCatalog.places.map(\.canonicalName).joined(separator: ", "))). \(MalaysiaPlaceCatalog.datasetNote)"
        case .ambiguousPlace(let name):
            "Place '\(name)' matches more than one catalog entry; use a canonical name."
        case .duplicatePlace(let name):
            "Place '\(name)' is listed twice; each scene place must be unique."
        case .invalidFrame:
            "Camera and reveal frames must be within the scene duration."
        case .invalidZoom:
            "Camera zoom must be finite, between 0.5 and 4."
        case .connectionNeedsClaims(let from, let to):
            "Sourced connection '\(from)' → '\(to)' needs at least one claimId; use kind illustrative instead."
        case .invalidSpec(let detail):
            detail
        }
    }
}

struct MapScenePlace: Decodable, Sendable {
    var name: String
    var label: String?
    var claimIds: [String]?
    var revealFrame: Int?
}

struct MapSceneConnection: Decodable, Sendable {
    var from: String
    var to: String
    var kind: String?
    var claimIds: [String]?
    var revealFrame: Int?
}

struct MapSceneCameraKey: Decodable, Sendable {
    var frame: Int
    var place: String
    var zoom: Double?
}

struct MapSceneInput: Decodable, Sendable {
    var places: [MapScenePlace]
    var connections: [MapSceneConnection]?
    var camera: [MapSceneCameraKey]?
    var durationFrames: Int?
    var width: Int?
    var height: Int?
}

struct MapScenePlaceRequest: Sendable {
    var place: MalaysiaPlace
    var label: String
    var claimIds: [String]
    var revealFrame: Int
}

struct MapSceneConnectionRequest: Sendable {
    var from: MalaysiaPlace
    var to: MalaysiaPlace
    var sourced: Bool
    var claimIds: [String]
    var revealFrame: Int
}

struct MapSceneCameraRequest: Sendable {
    var frame: Int
    var center: MalaysiaPlace
    var zoom: Double
}

struct MapSceneStyle {
    var pinColor: (r: Double, g: Double, b: Double) = (1, 0.25, 0.2)
    var routeColor: (r: Double, g: Double, b: Double) = (0.2, 0.55, 1)
    var labelColor: (r: Double, g: Double, b: Double) = (1, 1, 1)
    var backgroundColor: (r: Double, g: Double, b: Double) = (0.06, 0.09, 0.14)
}

struct MapSceneSpec {
    var places: [MapScenePlaceRequest]
    var connections: [MapSceneConnectionRequest]
    var camera: [MapSceneCameraRequest]
    var durationFrames: Int
    var width: Int
    var height: Int
    var style: MapSceneStyle = MapSceneStyle()

    static func validated(_ input: MapSceneInput, defaultWidth: Int, defaultHeight: Int) throws -> MapSceneSpec {
        let duration = input.durationFrames ?? 240
        guard (30...3600).contains(duration) else {
            throw MapSceneError.invalidSpec("durationFrames must be between 30 and 3600 (1s–2m at 30fps).")
        }
        let width = input.width ?? defaultWidth
        let height = input.height ?? defaultHeight
        guard (320...2048).contains(width), (240...2048).contains(height) else {
            throw MapSceneError.invalidSpec("width must be 320–2048 and height 240–2048.")
        }
        guard !input.places.isEmpty else {
            throw MapSceneError.invalidSpec("A map scene needs at least one place.")
        }
        var seen = Set<String>()
        var places: [MapScenePlaceRequest] = []
        for raw in input.places {
            let place = try MalaysiaPlaceCatalog.resolve(raw.name)
            guard seen.insert(place.canonicalName).inserted else { throw MapSceneError.duplicatePlace(name: raw.name) }
            let reveal = raw.revealFrame ?? 0
            guard (0..<duration).contains(reveal) else { throw MapSceneError.invalidFrame }
            let claimIds = (raw.claimIds ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let trimmedLabel = raw.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = trimmedLabel.isEmpty ? place.canonicalName : trimmedLabel
            places.append(MapScenePlaceRequest(place: place, label: label, claimIds: claimIds, revealFrame: reveal))
        }
        func resolvedPlace(_ raw: String) throws -> MalaysiaPlace {
            try MalaysiaPlaceCatalog.resolve(raw)
        }
        var scoped = Set(places.map(\.place.canonicalName))
        var connections: [MapSceneConnectionRequest] = []
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
            let claimIds = (raw.claimIds ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if kind == "sourced", claimIds.isEmpty {
                throw MapSceneError.connectionNeedsClaims(from: from.canonicalName, to: to.canonicalName)
            }
            let reveal = raw.revealFrame ?? 0
            guard (0..<duration).contains(reveal) else { throw MapSceneError.invalidFrame }
            connections.append(MapSceneConnectionRequest(from: from, to: to, sourced: kind == "sourced", claimIds: claimIds, revealFrame: reveal))
        }
        var camera: [MapSceneCameraRequest] = []
        for raw in input.camera ?? [] {
            guard (0..<duration).contains(raw.frame) else { throw MapSceneError.invalidFrame }
            let zoom = raw.zoom ?? 1
            guard zoom.isFinite, (0.5...4).contains(zoom) else { throw MapSceneError.invalidZoom }
            camera.append(MapSceneCameraRequest(frame: raw.frame, center: try resolvedPlace(raw.place), zoom: zoom))
        }
        if camera.isEmpty, let first = places.first {
            camera = [MapSceneCameraRequest(frame: 0, center: first.place, zoom: 1)]
        }
        camera.sort { $0.frame < $1.frame }
        return MapSceneSpec(places: places, connections: connections, camera: camera,
                            durationFrames: duration, width: width, height: height)
    }
}

/// Equirectangular projection about the scene center latitude. Plane is canvas
/// units, y-down, origin at the extent center.
enum MapProjection {
    struct Frame {
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
        let lon0 = spec.places.map(\.place.longitude).reduce(0, +) / Double(spec.places.count)
        let cosine = cos(lat0 * .pi / 180)
        func planar(_ place: MalaysiaPlace) -> (x: Double, y: Double) {
            // Equirectangular: meters per degree latitude ≈ constant, longitude scaled by cos(lat).
            ((place.longitude - lon0) * cosine, (lat0 - place.latitude))
        }
        let raw = spec.places.map { planar($0.place) }
        let spanX = max(0.2, (raw.map(\.x).max() ?? 0) - (raw.map(\.x).min() ?? 0))
        let spanY = max(0.2, (raw.map(\.y).max() ?? 0) - (raw.map(\.y).min() ?? 0))
        let baseScale = min(Double(spec.width) * 0.8 / spanX, Double(spec.height) * 0.8 / spanY)
        let center = CGPoint(x: Double(spec.width) / 2, y: Double(spec.height) / 2)
        let points = raw.map { CGPoint(x: $0.x * baseScale, y: $0.y * baseScale) }
        return Frame(points: points, baseScale: baseScale, center: center, latitude0: lat0, longitude0: lon0, cosine: cosine)
    }

    static func point(of place: MalaysiaPlace, in frame: Frame) -> CGPoint {
        CGPoint(x: (place.longitude - frame.longitude0) * frame.cosine * frame.baseScale,
                y: (frame.latitude0 - place.latitude) * frame.baseScale)
    }

    static func cameraScale(_ camera: MapSceneCameraRequest, in frame: Frame) -> Double {
        camera.zoom
    }

    /// Group position so the camera center lands on the canvas center. The layer
    /// anchor is the canvas center, so children render at anchor + plane*scale.
    static func groupPosition(for camera: MapSceneCameraRequest, in frame: Frame) -> CGPoint {
        let centerPlane = point(of: camera.center, in: frame)
        let scale = cameraScale(camera, in: frame)
        return CGPoint(x: frame.center.x - centerPlane.x * scale,
                       y: frame.center.y - centerPlane.y * scale)
    }

    /// Screen position of a plane point under a camera key (render-test oracle).
    static func screen(_ plane: CGPoint, camera: MapSceneCameraRequest, in frame: Frame) -> CGPoint {
        let centerPlane = point(of: camera.center, in: frame)
        let scale = cameraScale(camera, in: frame)
        return CGPoint(x: frame.center.x + (plane.x - centerPlane.x) * scale,
                       y: frame.center.y + (plane.y - centerPlane.y) * scale)
    }
}

extension MapSceneSpec {
    var digest: String {
        var hasher = Hasher()
        for place in places { place.place.canonicalName.hash(into: &hasher) }
        for connection in connections {
            connection.from.canonicalName.hash(into: &hasher)
            connection.to.canonicalName.hash(into: &hasher)
        }
        for key in camera { key.frame.hash(into: &hasher); key.zoom.hash(into: &hasher) }
        durationFrames.hash(into: &hasher)
        width.hash(into: &hasher)
        height.hash(into: &hasher)
        return String(describing: hasher.finalize())
    }

    var receipt: [String: Any] {
        [
            "projection": "equirectangular",
            "dataset": MalaysiaPlaceCatalog.datasetNote,
            "digest": digest,
            "canvas": [width, height],
            "durationFrames": durationFrames,
            "places": places.map { ["name": $0.place.canonicalName, "label": $0.label, "latitude": $0.place.latitude,
                                   "longitude": $0.place.longitude, "island": $0.place.island,
                                   "claimIds": $0.claimIds, "revealFrame": $0.revealFrame] },
            "connections": connections.map { ["from": $0.from.canonicalName, "to": $0.to.canonicalName,
                                              "sourced": $0.sourced, "claimIds": $0.claimIds, "revealFrame": $0.revealFrame] },
            "camera": camera.map { ["frame": $0.frame, "place": $0.center.canonicalName, "zoom": $0.zoom] },
        ]
    }
}

/// Builds a Lottie scene whose shape layer and label text layers share one
/// camera transform, so labels stay attached to their pins while zooming.
enum MapSceneLottie {
    static let fps = 30

    static func json(for spec: MapSceneSpec) -> [String: Any] {
        let frame = MapProjection.frame(for: spec)
        let duration = spec.durationFrames
        let center = frame.center
        let keys = spec.camera

        func positionKeys() -> [String: Any] {
            if keys.count == 1 {
                let p = MapProjection.groupPosition(for: keys[0], in: frame)
                return ["a": 0, "k": [Double(p.x), Double(p.y), 0]]
            }
            let frames = keys.map { key -> [String: Any] in
                let p = MapProjection.groupPosition(for: key, in: frame)
                return ["i": ["x": [0.667], "y": [1]], "o": ["x": [0.333], "y": [0]],
                        "t": key.frame, "s": [Double(p.x), Double(p.y), 0]]
            }
            return ["a": 1, "k": frames]
        }

        func scaleKeys() -> [String: Any] {
            if keys.count == 1 {
                let s = MapProjection.cameraScale(keys[0], in: frame) * 100
                return ["a": 0, "k": [s, s, 100]]
            }
            let frames = keys.map { key -> [String: Any] in
                let s = MapProjection.cameraScale(key, in: frame) * 100
                return ["i": ["x": [0.667], "y": [1]], "o": ["x": [0.333], "y": [0]],
                        "t": key.frame, "s": [s, s, 100]]
            }
            return ["a": 1, "k": frames]
        }

        func opacityKeys(reveal: Int) -> [String: Any] {
            guard reveal > 0 else { return ["a": 0, "k": 100] }
            return ["a": 1, "k": [
                ["i": ["x": [0.833], "y": [0.833]], "o": ["x": [0.167], "y": [0.167]], "t": 0, "s": [0]],
                ["i": ["x": [0.833], "y": [0.833]], "o": ["x": [0.167], "y": [0.167]], "t": reveal, "s": [100]],
            ]]
        }

        func group(_ name: String, items: [[String: Any]], reveal: Int = 0) -> [String: Any] {
            var tr: [String: Any] = ["ty": "tr", "p": ["a": 0, "k": [0, 0]], "a": ["a": 0, "k": [0, 0]],
                                     "s": ["a": 0, "k": [100, 100]], "r": ["a": 0, "k": 0],
                                     "sk": ["a": 0, "k": 0], "sa": ["a": 0, "k": 0]]
            tr["o"] = opacityKeys(reveal: reveal)
            return ["ty": "gr", "nm": name, "np": items.count, "mn": "AD Group",
                    "hd": false, "it": items + [tr]]
        }

        func fill(_ c: (r: Double, g: Double, b: Double), opacity: Double = 100) -> [String: Any] {
            ["ty": "fl", "c": ["a": 0, "k": [c.r, c.g, c.b, 1]], "o": ["a": 0, "k": opacity],
             "r": ["a": 0, "k": 2], "bm": 0]
        }

        // Lottie layer coords run top-left; plane origin is the canvas center.
        func local(_ plane: CGPoint) -> CGPoint {
            CGPoint(x: center.x + plane.x, y: center.y + plane.y)
        }

        var shapeItems: [[String: Any]] = []
        // Connections as stroked paths between projected points.
        for connection in spec.connections {
            let a = local(MapProjection.point(of: connection.from, in: frame))
            let b = local(MapProjection.point(of: connection.to, in: frame))
            let path: [String: Any] = ["ty": "sh",
                                       "ks": ["a": 0, "k": ["i": [[0, 0], [0, 0]], "o": [[0, 0], [0, 0]],
                                                   "v": [[Double(a.x), Double(a.y)], [Double(b.x), Double(b.y)]], "c": false]]]
            let stroke: [String: Any] = ["ty": "st", "c": ["a": 0, "k": [spec.style.routeColor.r, spec.style.routeColor.g, spec.style.routeColor.b, 1]],
                                         "o": ["a": 0, "k": 80], "w": ["a": 0, "k": connection.sourced ? 8 : 4],
                                         "lc": 1, "lj": 1, "ml": 4]
            shapeItems.append(group("route", items: [path, stroke], reveal: connection.revealFrame))
        }

        for (index, place) in spec.places.enumerated() {
            let pt = local(frame.points[index])
            let ellipse: [String: Any] = ["ty": "el",
                                           "p": ["a": 0, "k": [Double(pt.x), Double(pt.y - 14)]],
                                           "s": ["a": 0, "k": [18, 18]]]
            shapeItems.append(group("pin-\(place.place.canonicalName)", items: [ellipse, fill(spec.style.pinColor)],
                                    reveal: place.revealFrame))
        }

        let shapeLayer: [String: Any] = [
            "ddd": 0, "ind": 1, "ty": 4, "nm": "map", "sr": 1, "ks": [
                "o": ["a": 0, "k": 100],
                "r": ["a": 0, "k": 0],
                "p": positionKeys(),
                "a": ["a": 0, "k": [Double(center.x), Double(center.y), 0]],
                "s": scaleKeys(),
            ], "ao": 0, "shapes": shapeItems, "ip": 0, "op": duration, "st": 0, "bm": 0,
        ]

        let bg: [String: Any] = [
            "ddd": 0, "ind": 0, "ty": 1, "nm": "background", "sr": 1, "sw": spec.width, "sh": spec.height,
            "sc": "#\(Self.hex(spec.style.backgroundColor))",
            "ks": ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
                   "p": ["a": 0, "k": [0, 0, 0]],
                   "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]]],
            "ao": 0, "ip": 0, "op": duration, "st": 0, "bm": 0,
        ]

        // Layers render first-on-top; the background goes last (bottom).
        var layers: [[String: Any]] = [shapeLayer]
        var ind = 2
        for (index, place) in spec.places.enumerated() {
            let pt = local(frame.points[index])
            layers.append([
                "ddd": 0, "ind": ind, "ty": 5, "nm": "label-\(place.place.canonicalName)",
                "parent": 1, "sr": 1,
                "ks": [
                    "o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
                    "p": ["a": 0, "k": [Double(pt.x), Double(pt.y - 34), 0]],
                    "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]],
                ],
                "ao": 0, "ip": place.revealFrame, "op": duration, "st": 0, "bm": 0,
                "t": [
                    "d": ["k": [[
                        "s": ["s": 30, "f": "Helvetica-Bold", "t": place.label, "j": 1,
                                "tr": 0, "lh": 36, "ls": 0, "a": 24,
                                "fc": [spec.style.labelColor.r, spec.style.labelColor.g, spec.style.labelColor.b, 1]],
                        "t": 0,
                    ]]],
                    "f": [[
                        "fName": "Helvetica-Bold", "fFamily": "Helvetica", "fStyle": "Bold", "ascent": 24,
                    ]],
                    "p": ["a": 0, "k": [0, 0, 0]],
                    "m": ["g": 1, "a": ["a": 0, "k": [0, 0]]],
                    "a": [],
                ],
            ])
            ind += 1
        }
        layers.append(bg)

        return [
            "v": "5.7.0", "fr": fps, "ip": 0, "op": duration,
            "w": spec.width, "h": spec.height, "nm": "map", "ddd": 0,
            "assets": [], "fonts": [[
                "fName": "Helvetica-Bold", "fFamily": "Helvetica", "fStyle": "Bold", "ascent": 24,
            ]],
            "layers": layers,
        ]
    }

    static func data(for spec: MapSceneSpec) throws -> Data {
        try JSONSerialization.data(withJSONObject: json(for: spec), options: [.sortedKeys])
    }

    static func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
        String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
}
