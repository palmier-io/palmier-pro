import Foundation

struct MapCoordinate: Codable, Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    func validated() throws -> Self {
        guard latitude.isFinite, longitude.isFinite,
              (-85...85).contains(latitude), (-180...180).contains(longitude) else {
            throw MapSceneError.invalidSpec("Coordinates must be finite WGS-84 values: latitude -85...85, longitude -180...180.")
        }
        return self
    }
}

struct MapAtlasRegion: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var country: String
    var level: String
    var classification: String?
    var aliases: [String]
    var center: MapCoordinate
    var polygons: [[[MapCoordinate]]]

    var location: MapSceneLocation {
        MapSceneLocation(canonicalName: id, aliases: aliases + [name], latitude: center.latitude,
                         longitude: center.longitude, island: false,
                         note: "Approximate Natural Earth editorial centroid.", regionId: id)
    }
}

struct MapAtlas: Codable, Sendable {
    var version: String
    var attribution: String
    var sources: [String]
    var regions: [MapAtlasRegion]

    static let empty = MapAtlas(version: "centroids", attribution: MalaysiaPlaceCatalog.datasetNote,
                                sources: [], regions: [])

    func region(named value: String) throws -> MapAtlasRegion {
        let key = Self.key(value)
        if let exact = regions.first(where: { Self.key($0.id) == key }) { return exact }
        let matches = regions.filter { Self.key($0.name) == key || $0.aliases.contains { Self.key($0) == key } }
        guard matches.count == 1 else {
            if matches.isEmpty { throw MapSceneError.unresolvedPlace(name: value) }
            throw MapSceneError.invalidSpec("Ambiguous region '\(value)'; use \(matches.map(\.id).joined(separator: ", ")).")
        }
        return matches[0]
    }

    func location(named value: String) throws -> MapSceneLocation {
        let key = Self.key(value)
        if MalaysiaPlaceCatalog.places.contains(where: { Self.key($0.canonicalName) == key || $0.aliases.contains { Self.key($0) == key } }) {
            return try MalaysiaPlaceCatalog.resolve(value)
        }
        return try region(named: value).location
    }

    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}

actor MapAtlasStore {
    static let shared = MapAtlasStore()
    private var cached: MapAtlas?
    private var loading: Task<MapAtlas, Error>?

    func snapshot() async throws -> MapAtlas {
        if let cached { return cached }
        if let loading { return try await loading.value }
        let task = Task { try await Self.load() }
        loading = task
        do {
            let value = try await task.value
            cached = value
            loading = nil
            return value
        } catch {
            loading = nil
            throw error
        }
    }

    @concurrent private static func load() async throws -> MapAtlas {
        guard let url = BundledResource.url("Maps/atlas.json") else {
            throw MapSceneError.invalidSpec("The bundled map atlas is missing; rebuild the application resources.")
        }
        return try JSONDecoder().decode(MapAtlas.self, from: Data(contentsOf: url))
    }
}
