import Foundation

extension ToolExecutor {
    private struct BuildMapSceneInput: DecodableToolArgs {
        let scene: MapSceneInput
        let name: String?
        let addToTimeline: Bool?
        let startFrame: Int?

        static let allowedKeys: Set<String> = Set((MapSceneToolSchema.build.inputSchema["properties"] as? [String: Any] ?? [:]).keys)
        private enum CodingKeys: String, CodingKey { case name, addToTimeline, startFrame }

        init(from decoder: Decoder) throws {
            scene = try MapSceneInput(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            addToTimeline = try c.decodeIfPresent(Bool.self, forKey: .addToTimeline)
            startFrame = try c.decodeIfPresent(Int.self, forKey: .startFrame)
        }
    }

    private struct ReadMapSceneInput: DecodableToolArgs {
        let mediaRef: String
        static let allowedKeys: Set<String> = ["mediaRef"]
    }

    private struct ListMapRegionsInput: DecodableToolArgs, Sendable {
        let query: String?
        let country: String?
        let level: String?
        let offset: Int?
        let limit: Int?
        static let allowedKeys: Set<String> = ["query", "country", "level", "offset", "limit"]
    }

    private struct MapReceipt: Encodable, Sendable {
        let mediaRef: String
        let name: String
        let path: String
        let type = "video"
        let projection = "equirectangular"
        let spec: MapSceneRecord
        let width: Int
        let height: Int
        let durationFrames: Int
        let fps: Int
        let changed: Bool
        let reused: Bool
        let undoSteps: Int
        let inLibrary = true
        let clipId: String?
        let placementFrames: Int?
    }

    func buildMapScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try MapSceneToolSchema.validateKeys(args, schema: MapSceneToolSchema.build.inputSchema, path: "build_map_scene")
        let input: BuildMapSceneInput = try decodeToolArgs(args, path: "build_map_scene")
        let result = try await editor.prepareMapScene(input.scene, name: input.name,
            addToTimeline: input.addToTimeline ?? false, startFrame: input.startFrame ?? 0)
        guard let record = result.asset.mapScene, let width = record.input.width, let height = record.input.height,
              let durationFrames = record.input.durationFrames, let fps = record.input.fps else {
            throw ToolError("build_map_scene: The published asset has an incomplete authored specification.")
        }
        let receipt = MapReceipt(mediaRef: result.asset.id, name: result.asset.name, path: result.asset.url.path,
            spec: record, width: width, height: height, durationFrames: durationFrames, fps: fps, changed: result.changed,
            reused: result.reused, undoSteps: result.changed ? 1 : 0, clipId: result.clipId, placementFrames: result.placementFrames)
        return .ok(try await Self.encodeMapValue(receipt))
    }

    func readMapScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ReadMapSceneInput = try decodeToolArgs(args, path: "read_map_scene")
        guard let asset = editor.mediaAssetsById[input.mediaRef], let record = asset.mapScene else {
            throw ToolError("read_map_scene: mediaRef must identify an existing generated map scene.")
        }
        struct ReadReceipt: Encodable, Sendable {
            let mediaRef: String
            let name: String
            let projection = "equirectangular"
            let spec: MapSceneRecord
        }
        return .ok(try await Self.encodeMapValue(ReadReceipt(mediaRef: asset.id, name: asset.name, spec: record)))
    }

    func listMapRegions(_ args: [String: Any]) async throws -> ToolResult {
        let input: ListMapRegionsInput = try decodeToolArgs(args, path: "list_map_regions")
        guard (0...10_000).contains(input.offset ?? 0), (1...100).contains(input.limit ?? 30),
              input.level == nil || ["country", "subdivision"].contains(input.level!) else {
            throw ToolError("list_map_regions: offset must be 0...10000, limit 1...100, level country or subdivision.")
        }
        if let query = input.query { _ = try MapSceneSpec.identifier(query) }
        if let country = input.country { _ = try MapSceneSpec.identifier(country) }
        let atlas = try await MapAtlasStore.shared.snapshot()
        return .ok(try await Self.regionSearch(input, atlas: atlas))
    }

    @concurrent private static func encodeMapValue<T: Encodable & Sendable>(_ value: T) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    @concurrent private static func regionSearch(_ input: ListMapRegionsInput, atlas: MapAtlas) async throws -> String {
        struct Component: Encodable {
            let index: Int
            let center: MapCoordinate
            let west: Double
            let south: Double
            let east: Double
            let north: Double
        }
        struct Region: Encodable {
            let id: String
            let name: String
            let country: String
            let level: String
            let classification: String?
            let aliases: [String]
            let center: MapCoordinate
            let components: [Component]
        }
        struct Search: Encodable {
            let atlasVersion: String
            let attribution: String
            let sources: [String]
            let total: Int
            let nextOffset: Int?
            let regions: [Region]
        }
        try Task.checkCancellation()
        let query = MapAtlas.key(input.query ?? "")
        let country: String?
        if let value = input.country {
            let region = try atlas.region(named: value)
            guard region.level == "country" else { throw ToolError("list_map_regions: country must identify a country, not a subdivision.") }
            country = region.country
        } else { country = nil }
        let found = atlas.regions.filter { region in
            (input.level == nil || region.level == input.level) && (country == nil || region.country == country)
                && (query.isEmpty || ([region.id, region.name] + region.aliases).contains { MapAtlas.key($0).contains(query) })
        }
        let start = min(found.count, input.offset ?? 0), end = min(found.count, start + (input.limit ?? 30))
        let regions = found[start..<end].map { region in
            Region(id: region.id, name: region.name, country: region.country, level: region.level,
                classification: region.classification, aliases: region.aliases, center: region.center,
                components: region.polygons.enumerated().map { index, polygon in
                    let points = polygon.flatMap { $0 }
                    return Component(index: index, center: MapSceneSpec.center(of: [polygon]),
                        west: points.map(\.longitude).min() ?? 0, south: points.map(\.latitude).min() ?? 0,
                        east: points.map(\.longitude).max() ?? 0, north: points.map(\.latitude).max() ?? 0)
                })
        }
        let data = try JSONEncoder().encode(Search(atlasVersion: atlas.version, attribution: atlas.attribution,
            sources: atlas.sources, total: found.count, nextOffset: end < found.count ? end : nil, regions: regions))
        return String(decoding: data, as: UTF8.self)
    }
}
