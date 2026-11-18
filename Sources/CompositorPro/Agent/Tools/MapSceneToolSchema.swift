import Foundation

enum MapSceneToolSchema {
    private static func object(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func array(_ items: [String: Any], maximum: Int, minimum: Int = 0) -> [String: Any] {
        ["type": "array", "items": items, "minItems": minimum, "maxItems": maximum]
    }

    private static func integer(_ minimum: Int, _ maximum: Int) -> [String: Any] {
        ["type": "integer", "minimum": minimum, "maximum": maximum]
    }

    private static func number(_ minimum: Double, _ maximum: Double) -> [String: Any] {
        ["type": "number", "minimum": minimum, "maximum": maximum]
    }

    private static var string: [String: Any] { ["type": "string", "minLength": 1, "maxLength": 160] }
    private static var boolean: [String: Any] { ["type": "boolean"] }
    private static var color: [String: Any] { ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"] }
    private static var frame: [String: Any] { integer(0, 21_600) }
    private static var claims: [String: Any] { array(string, maximum: 128) }
    private static var easing: [String: Any] { ["type": "string", "enum": MapSceneEasing.allCases.map(\.rawValue)] }
    private static var entrance: [String: Any] { ["type": "string", "enum": MapSceneEntrance.allCases.map(\.rawValue)] }
    private static var coordinate: [String: Any] { object(["latitude": number(-85, 85), "longitude": number(-180, 180)], required: ["latitude", "longitude"]) }

    private static func anchor(_ fields: [String: [String: Any]]) -> [String: [String: Any]] {
        fields.merging(["place": string, "latitude": number(-85, 85), "longitude": number(-180, 180)]) { first, _ in first }
    }

    static let build = AgentTool(
        name: .buildMapScene,
        description: "Build a silent animated geography/explainer video locally with real Natural Earth country outlines, relief, available subdivisions, timed region/flag fills, camera flights, route reveals, moving objects and bold text. Discover exact IDs and polygon components with list_map_regions. Unknown/ambiguous names are refused; other locations require explicit WGS-84 coordinates. Ships, cargo/packages, vehicles, people, money, arrows, gunfire, explosions, heat and rain can follow a curved/via route or timed waypoints. Objects remain anchored during camera moves. Use 1080x1920 for Shorts. All cue frames use the scene fps; pair measured narration/captions and mix_audio on the timeline. This is an equirectangular plane with simulated tilt, not a 3D globe or navigation map. An optional ready library image provides a georeferenced background; imageMediaRef supplies flag fills or custom objects. Publishes complete H.264 video and its persistent authored spec together; read_map_scene returns it for revision. addToTimeline places on an available non-overlapping visual track with one shared undo action. An identical retry reuses the asset and matching placement without another undo step. Name applies to newly created assets. Sourced links require claimIds; these annotations alone do not verify a factual claim.",
        inputSchema: object([
            "places": array(object([
                "name": string, "label": string, "claimIds": claims, "revealFrame": frame,
                "latitude": number(-85, 85), "longitude": number(-180, 180),
                "showPin": boolean, "showLabel": boolean,
            ], required: ["name"]), maximum: 64, minimum: 1),
            "connections": array(object([
                "id": string, "from": string, "to": string,
                "kind": ["type": "string", "enum": ["illustrative", "sourced"]], "claimIds": claims,
                "revealFrame": frame, "endFrame": frame, "revealFrames": integer(0, 120),
                "via": array(coordinate, maximum: 128), "arc": number(-1, 1),
                "color": color, "width": number(1, 24), "label": string, "distanceLabel": boolean,
            ], required: ["from", "to"]), maximum: 64),
            "camera": array(object(anchor([
                "frame": frame, "zoom": number(0.05, 128), "rotation": number(-180, 180),
                "tilt": number(0, 60), "easing": easing,
            ]), required: ["frame"]), maximum: 128),
            "regions": array(object([
                "name": string, "id": string, "label": string, "showLabel": boolean,
                "componentIndices": array(integer(0, 4095), maximum: 32, minimum: 1),
                "polygon": array(array(number(-180, 180), maximum: 2, minimum: 2), maximum: 4096, minimum: 4),
                "color": color, "opacity": number(0, 1), "imageMediaRef": string,
                "revealFrame": frame, "endFrame": frame, "pulse": boolean, "claimIds": claims,
            ], required: ["name"]), maximum: 64),
            "objects": array(object(anchor([
                "id": string, "kind": ["type": "string", "enum": MapSceneObjectKind.allCases.map(\.rawValue)],
                "routeId": string, "waypoints": array(object(anchor(["frame": frame]), required: ["frame"]), maximum: 128, minimum: 2),
                "startFrame": frame, "endFrame": frame, "size": number(8, 320), "color": color,
                "label": ["type": "string", "minLength": 1, "maxLength": 80], "imageMediaRef": string,
                "loopCount": integer(1, 16), "rotateToPath": boolean, "rotation": number(-180, 180), "easing": easing, "entrance": entrance,
            ]), required: ["id", "kind"]), maximum: 64),
            "texts": array(object([
                "id": string, "text": ["type": "string", "minLength": 1, "maxLength": 240], "place": string,
                "x": number(0, 1), "y": number(0, 1), "startFrame": frame, "endFrame": frame,
                "fontSize": number(10, 240), "color": color, "entrance": entrance, "rotation": number(-180, 180),
            ], required: ["id", "text"]), maximum: 64),
            "palette": object([
                "background": color, "land": color, "border": color, "pin": color, "route": color, "text": color,
                "labelSize": number(10, 160), "glow": number(0, 32), "relief": boolean,
            ]),
            "backgroundImage": object([
                "mediaRef": string, "west": number(-180, 180), "east": number(-180, 180),
                "south": number(-85, 85), "north": number(-85, 85),
            ], required: ["mediaRef", "west", "south", "east", "north"]),
            "fps": integer(1, 120), "durationFrames": integer(1, 21_600),
            "width": integer(320, 3840), "height": integer(180, 3840),
            "name": string, "addToTimeline": boolean, "startFrame": integer(0, maxFrameArg),
        ], required: ["places"])
    )

    static let list = AgentTool(name: .listMapRegions,
        description: "Search the bundled Natural Earth atlas before building map scenes. Returns exact country:/subdivision: IDs, aliases, classifications, editorial centers and numbered polygon component bounds. Use componentIndices to highlight separate land masses (for example Peninsular/East Malaysia). Georgia is ambiguous; select country:GEO or subdivision:US-GA. Boundaries are generalized and some subdivisions are unavailable; use explicit coordinates/custom closed [longitude,latitude] polygons for finer regions. Pagination is offset/limit.",
        inputSchema: object([
            "query": string, "country": string, "level": ["type": "string", "enum": ["country", "subdivision"]],
            "offset": integer(0, 10_000), "limit": integer(1, 100),
        ]))

    static let read = AgentTool(name: .readMapScene,
        description: "Read the persisted authored map specification, content digest, atlas/renderer versions and image fingerprints from a generated map asset, including after save/reopen. Revise its spec.input and pass it to build_map_scene to generate an updated asset. Does not alter the library or timeline.",
        inputSchema: object(["mediaRef": string], required: ["mediaRef"]))

    static func validateKeys(_ value: Any, schema: [String: Any], path: String) throws {
        if let dictionary = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]] {
            try validateUnknownKeys(dictionary, allowed: Set(properties.keys), path: path)
            for (key, child) in dictionary {
                if let childSchema = properties[key] { try validateKeys(child, schema: childSchema, path: "\(path).\(key)") }
            }
        } else if let values = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, child) in values.enumerated() { try validateKeys(child, schema: items, path: "\(path)[\(index)]") }
        }
    }
}
