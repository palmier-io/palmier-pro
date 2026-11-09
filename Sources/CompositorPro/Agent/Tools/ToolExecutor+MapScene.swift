import Foundation

extension ToolExecutor {
    private struct BuildMapSceneInput: DecodableToolArgs {
        var places: [MapScenePlace]
        var connections: [MapSceneConnection]?
        var camera: [MapSceneCameraKey]?
        var durationFrames: Int?
        var width: Int?
        var height: Int?
        var name: String?
        var addToTimeline: Bool?
        var startFrame: Int?

        static let allowedKeys: Set<String> = [
            "places", "connections", "camera", "durationFrames", "width", "height",
            "name", "addToTimeline", "startFrame",
        ]
    }

    /// Builds an editable-spec geographic scene: validates places against the
    /// Malaysia catalog, projects once (equirectangular), and bakes a Lottie map
    /// whose pins, routes, and labels share one camera transform.
    func buildMapScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: BuildMapSceneInput = try decodeToolArgs(args, path: "build_map_scene")
        let spec: MapSceneSpec
        do {
            spec = try MapSceneSpec.validated(
                MapSceneInput(places: input.places, connections: input.connections, camera: input.camera,
                              durationFrames: input.durationFrames, width: input.width, height: input.height),
                defaultWidth: editor.timeline.width, defaultHeight: editor.timeline.height)
        } catch let error as MapSceneError {
            throw ToolError("build_map_scene: \(error.localizedDescription ?? error.errorDescription ?? "invalid spec")")
        }

        let addToTimeline = input.addToTimeline ?? false
        let startFrame = input.startFrame ?? 0
        guard (0...1_099_511_627_776).contains(startFrame) else {
            throw ToolError("build_map_scene: startFrame is out of range.")
        }
        let plan = try await editor.prepareMapScene(spec, name: input.name, addToTimeline: addToTimeline, startFrame: startFrame)
        var payload: [String: Any] = [
            "mediaRef": plan.asset.id,
            "name": plan.asset.name,
            "path": plan.asset.url.path,
            "type": plan.asset.type.rawValue,
            "width": spec.width,
            "height": spec.height,
            "durationFrames": spec.durationFrames,
            "spec": spec.receipt,
            "changed": true,
            "inLibrary": true,
            "undoSteps": 0,
        ]
        if let clipId = plan.clipId { payload["clipId"] = clipId }
        if !plan.warnings.isEmpty { payload["warnings"] = plan.warnings }
        payload["notes"] = [
            "A baked video of the authored map specification. Rebuild with corrected places to regenerate; the placement receipt carries the spec digest and catalog coordinates.",
            "Coordinates are approximate editorial centroids; illustrative links carry no measured claim.",
        ]
        return .ok(Self.jsonString(payload) ?? "{}")
    }
}
